module Instagram
  class Client
    module FeedFetchingService
    def fetch_profile_feed_items_for_analysis(username:, user_id:, posts_limit:)
      http_result = fetch_profile_feed_items_via_http(
        username: username,
        user_id: user_id,
        posts_limit: posts_limit
      )
      return http_result if Array(http_result[:items]).any?

      browser_result = fetch_profile_feed_items_via_browser_context(
        username: username,
        user_id_hint: user_id,
        posts_limit: posts_limit
      )
      return browser_result if Array(browser_result[:items]).any?

      http_result.merge(
        browser_fallback_attempted: true,
        browser_fallback_error: browser_result[:error].to_s.presence
      )
    end

    def fetch_profile_feed_items_via_http(username:, user_id:, posts_limit:)
      limit = posts_limit.to_i if posts_limit.present?
      limit = nil if limit.to_i <= 0
      return { source: "http_feed_api", user_id: nil, pages_fetched: 0, items: [] } if user_id.to_s.blank?

      remaining = limit
      max_id = nil
      pages = 0
      items = []
      seen_max_ids = Set.new
      seen_item_keys = Set.new
      more_available = false

      loop do
        break if pages >= PROFILE_FEED_MAX_PAGES
        break if remaining.present? && remaining <= 0
        break if max_id.present? && seen_max_ids.include?(max_id)

        seen_max_ids << max_id if max_id.present?
        count = remaining.present? ? [ remaining, PROFILE_FEED_PAGE_SIZE ].min : PROFILE_FEED_PAGE_SIZE
        feed = fetch_user_feed(user_id: user_id, referer_username: username, count: count, max_id: max_id)
        break unless feed.is_a?(Hash)

        page_items = Array(feed["items"]).select { |item| item.is_a?(Hash) }
        break if page_items.empty?

        pages += 1
        deduped = dedupe_profile_feed_items(items: page_items, seen_keys: seen_item_keys, max_items: remaining)
        items.concat(deduped)
        remaining -= deduped.length if remaining.present?

        next_max_id = feed["next_max_id"].to_s.strip.presence
        more_available = ActiveModel::Type::Boolean.new.cast(feed["more_available"])
        max_id = next_max_id
        break if max_id.blank?
      end

      {
        source: "http_feed_api",
        user_id: user_id.to_s,
        pages_fetched: pages,
        final_max_id: max_id,
        more_available: more_available,
        items: limit.present? ? items.first(limit) : items
      }
    rescue StandardError => e
      {
        source: "http_feed_api",
        user_id: user_id.to_s.presence,
        pages_fetched: 0,
        error: e.message.to_s,
        items: []
      }
    end

    def fetch_profile_feed_items_via_browser_context(username:, user_id_hint:, posts_limit:)
      limit = posts_limit.to_i if posts_limit.present?
      limit = nil if limit.to_i <= 0
      max_items = limit.present? ? limit : PROFILE_FEED_BROWSER_ITEM_CAP

      with_recoverable_session(label: "profile_analysis_posts_browser_fallback") do
        with_authenticated_driver do |driver|
          driver.navigate.to("#{INSTAGRAM_BASE_URL}/#{username}/")
          wait_for(driver, css: "body", timeout: 10)
          dismiss_common_overlays!(driver)

          payload =
            driver.execute_async_script(
              <<~JS,
                const username = String(arguments[0] || "").trim();
                const userIdHint = String(arguments[1] || "").trim();
                const maxItems = Math.max(1, Number(arguments[2] || 0));
                const pageSize = Math.max(1, Number(arguments[3] || 30));
                const maxPages = Math.max(1, Number(arguments[4] || 100));
                const done = arguments[arguments.length - 1];

                const out = {
                  source: "browser_feed_api",
                  user_id: null,
                  pages_fetched: 0,
                  final_max_id: null,
                  items: [],
                  error: null
                };

                const readJson = async (path) => {
                  const resp = await fetch(path, {
                    method: "GET",
                    credentials: "include",
                    headers: {
                      "Accept": "application/json, text/plain, */*",
                      "X-Requested-With": "XMLHttpRequest"
                    }
                  });
                  if (!resp.ok) throw new Error(`HTTP ${resp.status} for ${path}`);
                  return await resp.json();
                };

                (async () => {
                  try {
                    let userId = userIdHint;
                    if (!userId) {
                      const profile = await readJson(`/api/v1/users/web_profile_info/?username=${encodeURIComponent(username)}`);
                      userId = String((profile && profile.data && profile.data.user && profile.data.user.id) || "").trim();
                    }
                    if (!userId) {
                      out.error = "browser_profile_user_id_missing";
                      done(out);
                      return;
                    }

                    out.user_id = userId;
                    let maxId = "";
                    let remaining = maxItems;
                    const seenCursors = new Set();

                    for (let page = 0; page < maxPages; page += 1) {
                      if (remaining <= 0) break;
                      if (maxId && seenCursors.has(maxId)) break;
                      if (maxId) seenCursors.add(maxId);

                      const count = Math.min(pageSize, remaining);
                      const query = new URLSearchParams({ count: String(count) });
                      if (maxId) query.set("max_id", maxId);
                      const feed = await readJson(`/api/v1/feed/user/${encodeURIComponent(userId)}/?${query.toString()}`);
                      const pageItems = Array.isArray(feed && feed.items) ? feed.items : [];
                      if (pageItems.length === 0) break;

                      out.items.push(...pageItems);
                      out.pages_fetched += 1;
                      remaining -= pageItems.length;

                      const nextMaxId = String((feed && feed.next_max_id) || "").trim();
                      if (!nextMaxId || nextMaxId === maxId) {
                        maxId = nextMaxId;
                        break;
                      }
                      maxId = nextMaxId;
                    }

                    out.final_max_id = maxId || null;
                  } catch (error) {
                    out.error = String((error && error.message) || error || "browser_feed_fetch_failed");
                  }
                  done(out);
                })();
              JS
              username.to_s,
              user_id_hint.to_s,
              max_items,
              PROFILE_FEED_PAGE_SIZE,
              PROFILE_FEED_MAX_PAGES
            )

          payload_hash = payload.is_a?(Hash) ? payload : {}
          seen_item_keys = Set.new
          deduped = dedupe_profile_feed_items(
            items: Array(payload_hash["items"]),
            seen_keys: seen_item_keys,
            max_items: limit
          )

          {
            source: payload_hash["source"].to_s.presence || "browser_feed_api",
            user_id: payload_hash["user_id"].to_s.presence,
            pages_fetched: payload_hash["pages_fetched"].to_i,
            final_max_id: payload_hash["final_max_id"].to_s.presence,
            error: payload_hash["error"].to_s.presence,
            items: deduped
          }
        end
      end
    rescue StandardError => e
      {
        source: "browser_feed_api",
        user_id: user_id_hint.to_s.presence,
        pages_fetched: 0,
        error: e.message.to_s,
        items: []
      }
    end

    def extract_latest_post_from_profile_dom(driver)
      with_task_capture(driver: driver, task_name: "profile_latest_post_dom") do
        begin
          wait_for(driver, css: "body", timeout: 6)
          dismiss_common_overlays!(driver)

          # Wait for the grid to hydrate (Instagram often renders posts after JS loads).
          begin
            Selenium::WebDriver::Wait.new(timeout: 12).until do
              driver.find_elements(css: "article a[href^='/p/'], article a[href^='/reel/']").any? ||
                driver.page_source.to_s.include?("No posts yet") ||
                driver.page_source.to_s.include?("This Account is Private")
            end
          rescue Selenium::WebDriver::Error::TimeoutError
            nil
          end

          link =
            driver.find_elements(css: "article a[href^='/p/']").find(&:displayed?) ||
            driver.find_elements(css: "article a[href^='/reel/']").find(&:displayed?) ||
            driver.find_elements(css: "a[href^='/p/']").find(&:displayed?) ||
            driver.find_elements(css: "a[href^='/reel/']").find(&:displayed?)

          unless link
            next({ taken_at: nil, shortcode: nil })
          end

          href = link.attribute("href").to_s
          shortcode =
            if href.include?("/p/")
              href.split("/p/").last.to_s.split("/").first.to_s
            elsif href.include?("/reel/")
              href.split("/reel/").last.to_s.split("/").first.to_s
            end

          driver.execute_script("arguments[0].click()", link)

          time_el = wait_for(driver, css: "time[datetime]", timeout: 10)
          dt = time_el.attribute("datetime").to_s
          taken_at =
            begin
              Time.iso8601(dt).utc
            rescue StandardError
              Time.parse(dt).utc
            end

          begin
            driver.action.send_keys(:escape).perform
          rescue StandardError
            nil
          end

          { taken_at: taken_at, shortcode: shortcode.presence }
        rescue Selenium::WebDriver::Error::TimeoutError
          { taken_at: nil, shortcode: nil }
        rescue StandardError
          { taken_at: nil, shortcode: nil }
        end
      end
    end

    def extract_latest_post_from_profile_http(username, web_info: nil, driver: nil)
      username = normalize_username(username)
      return { taken_at: nil, shortcode: nil } if username.blank?

      data = web_info.is_a?(Hash) ? web_info : fetch_web_profile_info(username, driver: driver)
      return { taken_at: nil, shortcode: nil } unless data.is_a?(Hash)

      user = data.dig("data", "user")
      return { taken_at: nil, shortcode: nil } unless user.is_a?(Hash)

      node =
        user.dig("edge_owner_to_timeline_media", "edges")&.first&.dig("node") ||
        user.dig("edge_felix_video_timeline", "edges")&.first&.dig("node")

      if node.is_a?(Hash)
        ts = node["taken_at_timestamp"] || node["taken_at"] || node["taken_at_time"]
        taken_at =
          begin
            ts.present? ? Time.at(ts.to_i).utc : nil
          rescue StandardError
            nil
          end
        shortcode = node["shortcode"].to_s.strip.presence
        return { taken_at: taken_at, shortcode: shortcode }
      end

      # Fallback: fetch the user's feed items (this endpoint still works on builds where timeline edges are empty).
      user_id = user["id"].to_s.strip
      return { taken_at: nil, shortcode: nil } if user_id.blank?

      feed = fetch_user_feed(user_id: user_id, referer_username: username, count: 6, driver: driver)
      item = feed.is_a?(Hash) ? Array(feed["items"]).first : nil
      return { taken_at: nil, shortcode: nil } unless item.is_a?(Hash)

      taken_at =
        begin
          ts = item["taken_at"]
          ts.present? ? Time.at(ts.to_i).utc : nil
        rescue StandardError
          nil
        end

      shortcode = (item["code"] || item["shortcode"]).to_s.strip.presence

      { taken_at: taken_at, shortcode: shortcode }
    rescue StandardError
      { taken_at: nil, shortcode: nil }
    end

    def extract_feed_items_from_dom(driver)
      api_items = fetch_home_feed_items_via_api(limit: 50)
      return api_items if api_items.present?

      # Instagram feed markup changes a lot. We rely on robust link patterns (/p/ and /reel/).
      driver.execute_script(<<~JS)
        const out = [];
        const uniq = new Set();

        const linkEls = Array.from(document.querySelectorAll("a[href^='/p/'], a[href^='/reel/']"));
        for (const a of linkEls) {
          const href = (a.getAttribute("href") || "").trim();
          if (!href) continue;
          const parts = href.split("/");
          // /p/<shortcode>/...
          const idx = parts.findIndex((p) => p === "p" || p === "reel");
          if (idx < 0 || !parts[idx + 1]) continue;
          const kind = parts[idx];
          const shortcode = parts[idx + 1];
          if (!shortcode || uniq.has(shortcode)) continue;

          uniq.add(shortcode);

          // Try to find a nearby article container for metadata.
          let node = a;
          for (let j = 0; j < 8; j++) {
            if (!node) break;
            if (node.tagName && node.tagName.toLowerCase() === "article") break;
            node = node.parentElement;
          }
          const container = node && node.tagName && node.tagName.toLowerCase() === "article" ? node : a.closest("article") || a.parentElement;

          // Author username: attempt to find a link that looks like /username/
          let author = null;
          if (container) {
            const authorLink = Array.from(container.querySelectorAll("a[href^='/']")).find((x) => {
              const h = (x.getAttribute("href") || "").trim();
              if (!h) return false;
              if (h.startsWith("/p/") || h.startsWith("/reel/") || h.startsWith("/stories/") || h.startsWith("/explore/") || h.startsWith("/direct/")) return false;
              const seg = h.split("/").filter(Boolean)[0];
              return seg && seg.length <= 30 && /^[A-Za-z0-9._]+$/.test(seg);
            });
            if (authorLink) {
              const h = (authorLink.getAttribute("href") || "").trim();
              author = h.split("/").filter(Boolean)[0] || null;
            }
          }

          // Media URL: prefer the first visible img.
          let mediaUrl = null;
          let naturalWidth = null;
          let naturalHeight = null;
          if (container) {
            const img = Array.from(container.querySelectorAll("img")).find((img) => {
              const r = img.getBoundingClientRect();
              return r.width > 80 && r.height > 80;
            });
            if (img) {
              mediaUrl = img.currentSrc || img.getAttribute("src") || null;
              naturalWidth = Number(img.naturalWidth || 0) || null;
              naturalHeight = Number(img.naturalHeight || 0) || null;
            }
          }

          out.push({
            shortcode,
            post_kind: kind === "reel" ? "reel" : "post",
            author_username: author,
            media_url: mediaUrl,
            caption: null,
            metadata: { href, natural_width: naturalWidth, natural_height: naturalHeight }
          });
        }

        return out.slice(0, 60);
      JS
      .map do |h|
        {
          shortcode: h["shortcode"],
          post_kind: h["post_kind"],
          author_username: normalize_username(h["author_username"].to_s),
          author_ig_user_id: nil,
          media_url: h["media_url"].to_s,
          caption: h["caption"],
          taken_at: nil,
          metadata: h["metadata"] || {}
        }
      end
    rescue StandardError
      []
    end

    def dedupe_profile_feed_items(items:, seen_keys:, max_items: nil)
      out = []
      Array(items).each do |item|
        next unless item.is_a?(Hash)

        key =
          item["pk"].to_s.presence ||
          item["id"].to_s.presence ||
          item["code"].to_s.presence ||
          item["shortcode"].to_s.presence
        key ||= Digest::SHA256.hexdigest(item.to_json)
        next if key.blank? || seen_keys.include?(key)

        seen_keys << key
        out << item
        break if max_items.present? && out.length >= max_items.to_i
      end
      out
    end

    def fetch_user_feed(user_id:, referer_username:, count:, max_id: nil, driver: nil)
      normalized_user_id = user_id.to_s.strip
      return nil if normalized_user_id.blank?

      referer_user = normalize_username(referer_username)
      q = [ "count=#{count.to_i.clamp(1, 30)}" ]
      q << "max_id=#{CGI.escape(max_id.to_s)}" if max_id.present?
      ig_api_get_json(
        path: "/api/v1/feed/user/#{CGI.escape(normalized_user_id)}/?#{q.join('&')}",
        referer: "#{INSTAGRAM_BASE_URL}/#{referer_user.presence || referer_username.to_s}/",
        endpoint: "feed/user",
        username: referer_user.presence || referer_username.to_s,
        driver: driver,
        retries: 2
      )
    rescue StandardError
      nil
    end

    def fetch_home_feed_items_via_api(limit: 50)
      n = limit.to_i.clamp(1, 60)
      body = ig_api_get_json(path: "/api/v1/feed/timeline/?count=#{n}", referer: INSTAGRAM_BASE_URL)
      return [] unless body.is_a?(Hash)

      # Newer payloads often use feed_items with nested media_or_ad.
      feed_items = Array(body["feed_items"])
      raw_items =
        if feed_items.present?
          feed_items.map { |entry| entry.is_a?(Hash) ? (entry["media_or_ad"] || entry["media"]) : nil }.compact
        else
          Array(body["items"])
        end

      raw_items.filter_map { |item| extract_home_feed_item_from_api(item) }.first(n)
    rescue StandardError
      []
    end

    def extract_home_feed_item_from_api(item)
      return nil unless item.is_a?(Hash)

      shortcode = (item["code"] || item["shortcode"]).to_s.strip
      return nil if shortcode.blank?

      media_type = item["media_type"].to_i
      product_type = item["product_type"].to_s.downcase
      post_kind = product_type.include?("clips") ? "reel" : "post"
      post_kind = "post" if post_kind.blank?

      image_candidate =
        if media_type == 8
          carousel = Array(item["carousel_media"]).select { |m| m.is_a?(Hash) }
          chosen = carousel.find { |m| m["media_type"].to_i == 2 } || carousel.find { |m| m["media_type"].to_i == 1 } || carousel.first
          chosen&.dig("image_versions2", "candidates", 0)
        else
          item.dig("image_versions2", "candidates", 0)
        end
      video_candidate =
        if media_type == 8
          carousel = Array(item["carousel_media"]).select { |m| m.is_a?(Hash) }
          chosen = carousel.find { |m| m["media_type"].to_i == 2 } || carousel.first
          Array(chosen&.dig("video_versions")).first
        else
          Array(item["video_versions"]).first
        end

      image_url = CGI.unescapeHTML(image_candidate&.dig("url").to_s).strip.presence
      video_url = CGI.unescapeHTML(video_candidate&.dig("url").to_s).strip.presence
      width = image_candidate&.dig("width")
      height = image_candidate&.dig("height")
      taken_at =
        begin
          ts = item["taken_at"] || item["taken_at_timestamp"] || item["device_timestamp"]
          ts.present? ? Time.at(ts.to_i).utc : nil
        rescue StandardError
          nil
        end

      friendship_status = item.dig("user", "friendship_status")
      author_following = extract_friendship_flag(friendship_status: friendship_status, key: "following")
      author_followed_by = extract_friendship_flag(friendship_status: friendship_status, key: "followed_by")
      suggested_context = suggestion_context_for_feed_item(item)

      metadata = {
        source: "api_timeline",
        media_id: (item["pk"] || item["id"]).to_s.presence,
        media_type: media_type,
        media_url_image: image_url.to_s.presence,
        media_url_video: video_url.to_s.presence,
        product_type: product_type,
        ad_id: item["ad_id"].to_s.presence,
        is_paid_partnership: ActiveModel::Type::Boolean.new.cast(item["is_paid_partnership"]),
        like_count: item["like_count"],
        comment_count: item["comment_count"],
        author_ig_user_id: item.dig("user", "pk").to_s.presence || item.dig("user", "id").to_s.presence,
        natural_width: width,
        natural_height: height,
        is_suggested: ActiveModel::Type::Boolean.new.cast(item["is_suggested"]),
        has_suggestion_context: suggested_context.present?,
        suggestion_context: suggested_context
      }
      metadata[:author_following] = author_following unless author_following.nil?
      metadata[:author_followed_by] = author_followed_by unless author_followed_by.nil?

      {
        shortcode: shortcode,
        post_kind: post_kind,
        author_username: normalize_username(item.dig("user", "username").to_s),
        author_ig_user_id: item.dig("user", "pk").to_s.presence || item.dig("user", "id").to_s.presence,
        media_url: (video_url.presence || image_url).to_s,
        caption: item.dig("caption", "text").to_s.presence,
        taken_at: taken_at,
        metadata: metadata
      }
    rescue StandardError
      nil
    end

    def extract_friendship_flag(friendship_status:, key:)
      return nil unless friendship_status.is_a?(Hash)
      return nil unless friendship_status.key?(key) || friendship_status.key?(key.to_sym)

      value =
        if friendship_status.key?(key)
          friendship_status[key]
        else
          friendship_status[key.to_sym]
        end
      ActiveModel::Type::Boolean.new.cast(value)
    rescue StandardError
      nil
    end

    def suggestion_context_for_feed_item(item)
      return "suggested_users" if Array(item["suggested_users"]).any?
      return "suggestion_social_context" if item["suggestion_social_context"].to_s.present?
      return "social_context" if item["social_context"].to_s.present?
      return "suggested_position" if item["suggested_position"].present?

      nil
    rescue StandardError
      nil
    end
    end
  end
end
