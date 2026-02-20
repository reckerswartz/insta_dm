module Instagram
  class Client
    module StoryApiSupport
      private

      def ig_api_get_json(path:, referer:)
        uri = URI.parse(path.to_s.start_with?("http") ? path.to_s : "#{INSTAGRAM_BASE_URL}#{path}")

        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = (uri.scheme == "https")
        http.open_timeout = 10
        http.read_timeout = 20

        req = Net::HTTP::Get.new(uri.request_uri)
        req["User-Agent"] = @account.user_agent.presence || "Mozilla/5.0"
        req["Accept"] = "application/json, text/plain, */*"
        req["X-Requested-With"] = "XMLHttpRequest"
        req["X-IG-App-ID"] = (@account.auth_snapshot.dig("ig_app_id").presence || "936619743392459")
        req["Referer"] = referer.to_s

        csrf = @account.cookies.find { |c| c["name"].to_s == "csrftoken" }&.dig("value").to_s
        req["X-CSRFToken"] = csrf if csrf.present?
        req["Cookie"] = cookie_header_for(@account.cookies)

        res = http.request(req)
        return nil unless res.is_a?(Net::HTTPSuccess)
        return nil unless res["content-type"].to_s.include?("json")

        JSON.parse(res.body.to_s)
      rescue StandardError
        nil
      end

      def fetch_story_reel(user_id:, referer_username:)
        uri = URI.parse("#{INSTAGRAM_BASE_URL}/api/v1/feed/reels_media/?reel_ids=#{CGI.escape(user_id.to_s)}")

        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = (uri.scheme == "https")
        http.open_timeout = 10
        http.read_timeout = 20

        req = Net::HTTP::Get.new(uri.request_uri)
        req["User-Agent"] = @account.user_agent.presence || "Mozilla/5.0"
        req["Accept"] = "application/json, text/plain, */*"
        req["X-Requested-With"] = "XMLHttpRequest"
        req["X-IG-App-ID"] = (@account.auth_snapshot.dig("ig_app_id").presence || "936619743392459")
        req["Referer"] = "#{INSTAGRAM_BASE_URL}/#{referer_username}/"

        csrf = @account.cookies.find { |c| c["name"].to_s == "csrftoken" }&.dig("value").to_s
        req["X-CSRFToken"] = csrf if csrf.present?
        req["Cookie"] = cookie_header_for(@account.cookies)

        res = http.request(req)
        return nil unless res.is_a?(Net::HTTPSuccess)

        body = JSON.parse(res.body.to_s)
      
        # Debug: Capture raw story reel data
        debug_story_reel_data(referer_username: referer_username, user_id: user_id, body: body)
      
        reels = body["reels"]
        if reels.is_a?(Hash)
          direct = reels[user_id.to_s]
          return direct if direct.is_a?(Hash)

          by_owner = reels.values.find { |entry| reel_entry_owner_id(entry) == user_id.to_s }
          return by_owner if by_owner.is_a?(Hash)

          if reels.size == 1
            Ops::StructuredLogger.warn(
              event: "instagram.story_reel.single_reel_without_key_match",
              payload: {
                requested_user_id: user_id.to_s,
                referer_username: referer_username.to_s,
                available_reel_keys: reels.keys.first(6)
              }
            )
            return reels.values.first
          end

          Ops::StructuredLogger.warn(
            event: "instagram.story_reel.requested_reel_missing",
            payload: {
              requested_user_id: user_id.to_s,
              referer_username: referer_username.to_s,
              available_reel_keys: reels.keys.first(10),
              reels_count: reels.size
            }
          )
          return nil
        end

        reels_media = body["reels_media"]
        if reels_media.is_a?(Array)
          by_owner = reels_media.find { |entry| reel_entry_owner_id(entry) == user_id.to_s }
          return by_owner if by_owner.is_a?(Hash)

          if reels_media.length == 1
            Ops::StructuredLogger.warn(
              event: "instagram.story_reel.single_reel_media_without_owner_match",
              payload: {
                requested_user_id: user_id.to_s,
                referer_username: referer_username.to_s
              }
            )
            return reels_media.first
          end

          Ops::StructuredLogger.warn(
            event: "instagram.story_reel.reels_media_owner_missing",
            payload: {
              requested_user_id: user_id.to_s,
              referer_username: referer_username.to_s,
              reels_media_count: reels_media.length
            }
          )
          return nil
        end

        body
      rescue StandardError
        nil
      end

      def resolve_story_media_for_current_context(driver:, username:, story_id:, fallback_story_key:, cache: nil)
        uname = normalize_username(username)
        sid = story_id.to_s.strip
        sid = "" if sid.casecmp("unknown").zero?

        api_story = resolve_story_item_via_api(username: uname, story_id: sid, cache: cache)
        if api_story.is_a?(Hash)
          url = api_story[:media_url].to_s
          if downloadable_story_media_url?(url)
            return {
              media_type: api_story[:media_type].to_s.presence || "unknown",
              url: url,
              width: api_story[:width],
              height: api_story[:height],
              source: "api_reels_media",
              story_id: api_story[:story_id].to_s,
              image_url: api_story[:image_url].to_s.presence,
              video_url: api_story[:video_url].to_s.presence,
              owner_user_id: api_story[:owner_user_id].to_s.presence,
              owner_username: api_story[:owner_username].to_s.presence,
              media_variant_count: Array(api_story[:media_variants]).length,
              primary_media_index: api_story[:primary_media_index],
              primary_media_source: api_story[:primary_media_source].to_s.presence,
              carousel_media: Array(api_story[:carousel_media])
            }
          end
        end

        dom_story = resolve_story_item_via_dom(driver: driver)
        if dom_story.is_a?(Hash)
          dom_media_url = dom_story[:media_url].to_s
          if downloadable_story_media_url?(dom_media_url)
            hinted_story_id = story_id_hint_from_media_url(dom_media_url).to_s
            return {
              media_type: dom_story[:media_type].to_s.presence || "unknown",
              url: dom_media_url,
              width: dom_story[:width],
              height: dom_story[:height],
              source: "dom_visible_media",
              story_id: sid.presence || hinted_story_id.presence || fallback_story_key.to_s,
              image_url: dom_story[:image_url].to_s.presence,
              video_url: dom_story[:video_url].to_s.presence,
              owner_user_id: nil,
              owner_username: nil,
              media_variant_count: 1,
              primary_media_index: 0,
              primary_media_source: "dom",
              carousel_media: []
            }
          end
        end

        Ops::StructuredLogger.warn(
          event: "instagram.story_media.api_unresolved",
          payload: {
            username: uname,
            story_id: sid.presence || fallback_story_key.to_s,
            source: "api_then_dom_resolution"
          }
        )
        {
          media_type: nil,
          url: nil,
          width: nil,
          height: nil,
          source: "api_unresolved",
          story_id: sid.presence || fallback_story_key.to_s,
          image_url: nil,
          video_url: nil,
          owner_user_id: nil,
          owner_username: nil,
          media_variant_count: 0,
          primary_media_index: nil,
          primary_media_source: nil,
          carousel_media: []
        }
      rescue StandardError
        {
          media_type: nil,
          url: nil,
          width: nil,
          height: nil,
          source: "api_unresolved_error",
          story_id: sid.presence || fallback_story_key.to_s,
          image_url: nil,
          video_url: nil,
          owner_user_id: nil,
          owner_username: nil,
          media_variant_count: 0,
          primary_media_index: nil,
          primary_media_source: nil,
          carousel_media: []
        }
      end

      def resolve_story_item_via_dom(driver:)
        payload = driver.execute_script(<<~JS)
          const out = {
            media_url: "",
            media_type: "",
            image_url: "",
            video_url: "",
            width: null,
            height: null
          };

          const isVisible = (el) => {
            if (!el) return false;
            const style = window.getComputedStyle(el);
            if (!style || style.display === "none" || style.visibility === "hidden" || style.opacity === "0") return false;
            const rect = el.getBoundingClientRect();
            if (rect.width < 220 || rect.height < 220) return false;
            return rect.bottom > 0 && rect.top < window.innerHeight;
          };

          const absUrl = (value) => {
            if (!value) return "";
            const str = value.toString().trim();
            if (!str) return "";
            try { return new URL(str, window.location.href).toString(); } catch (e) { return str; }
          };

          const blockedAvatarLikeUrl = (value) => {
            const src = (value || "").toString().toLowerCase();
            if (!src) return true;
            if (src.startsWith("data:")) return true;
            if (src.startsWith("blob:")) return true;
            if (src.startsWith("mediastream:")) return true;
            if (src.startsWith("javascript:")) return true;
            if (src.includes("/t51.2885-19/")) return true;
            if (src.includes("profile_pic")) return true;
            if (src.includes("s150x150")) return true;
            return false;
          };

          const centerBonus = (rect) => {
            const cx = rect.left + (rect.width / 2);
            const cy = rect.top + (rect.height / 2);
            const dx = Math.abs(cx - (window.innerWidth / 2));
            const dy = Math.abs(cy - (window.innerHeight / 2));
            const distance = Math.sqrt((dx * dx) + (dy * dy));
            return Math.max(0, 500 - distance);
          };

          const candidates = [];
          Array.from(document.querySelectorAll("video, img")).forEach((el) => {
            if (!isVisible(el)) return;
            const rect = el.getBoundingClientRect();
            const mediaType = el.tagName.toLowerCase() === "video" ? "video" : "image";
            const src = absUrl(
              mediaType === "video" ?
                (el.currentSrc || el.src || el.getAttribute("src")) :
                (el.currentSrc || el.src || el.getAttribute("src"))
            );
            if (!src || blockedAvatarLikeUrl(src)) return;

            let score = rect.width * rect.height;
            score += centerBonus(rect);
            if (mediaType === "video") score += 1500;
            if (src.includes("scontent")) score += 1000;
            if (src.includes("/stories/")) score += 500;

            candidates.push({
              score: score,
              mediaType: mediaType,
              src: src,
              width: Math.round(rect.width),
              height: Math.round(rect.height),
              poster: mediaType === "video" ? absUrl(el.poster || "") : ""
            });
          });

          candidates.sort((a, b) => b.score - a.score);
          const chosen = candidates[0];
          if (!chosen) return out;

          out.media_url = chosen.src;
          out.media_type = chosen.mediaType;
          out.width = chosen.width;
          out.height = chosen.height;
          if (chosen.mediaType === "video") {
            out.video_url = chosen.src;
            out.image_url = chosen.poster || "";
          } else {
            out.image_url = chosen.src;
            out.video_url = "";
          }
          return out;
        JS

        return nil unless payload.is_a?(Hash)

        media_url = payload["media_url"].to_s.presence
        return nil if media_url.blank?

        media_type = payload["media_type"].to_s
        {
          media_url: media_url,
          media_type: media_type.presence || "unknown",
          image_url: payload["image_url"].to_s,
          video_url: payload["video_url"].to_s,
          width: normalize_dom_story_media_dimension(payload["width"]),
          height: normalize_dom_story_media_dimension(payload["height"])
        }
      rescue StandardError
        nil
      end

      def normalize_dom_story_media_dimension(value)
        parsed = value.to_i
        parsed.positive? ? parsed : nil
      rescue StandardError
        nil
      end

      def resolve_story_item_via_api(username:, story_id:, cache: nil)
        uname = normalize_username(username)
        return nil if uname.blank?

        items = fetch_story_items_via_api(username: uname, cache: cache)
        return nil unless items.is_a?(Array)
        return nil if items.empty?

        sid = story_id.to_s.strip
        if sid.present?
          item = items.find { |s| s.is_a?(Hash) && s[:story_id].to_s == sid }
          return item if item
        end

        # Only pick first item without story_id when unambiguous.
        return items.first if sid.blank? && items.length == 1

        nil
      rescue StandardError
        nil
      end

      def fetch_story_items_via_api(username:, cache: nil)
        uname = normalize_username(username)
        return [] if uname.blank?

        cache_key = "stories:#{uname}"
        if cache.is_a?(Hash) && cache[cache_key].is_a?(Hash)
          cached = cache[cache_key][:items]
          return cached if cached.is_a?(Array)
        end

        web_info = fetch_web_profile_info(uname)
        user = web_info.is_a?(Hash) ? web_info.dig("data", "user") : nil
        user_id = user.is_a?(Hash) ? user["id"].to_s.strip : ""
        return [] if user_id.blank?

        reel = fetch_story_reel(user_id: user_id, referer_username: uname)
        raw_items = reel.is_a?(Hash) ? Array(reel["items"]) : []
        stories = raw_items.filter_map { |item| extract_story_item(item, username: uname, reel_owner_id: user_id) }

        if cache.is_a?(Hash)
          cache[cache_key] = { user_id: user_id, items: stories, fetched_at: Time.current.utc.iso8601(3) }
        end
        stories
      rescue StandardError
        []
      end

      def extract_story_item(item, username:, reel_owner_id: nil)
        return nil unless item.is_a?(Hash)

        story_id = (item["pk"] || item["id"]).to_s.split("_").first.to_s.strip
        return nil if story_id.blank?

        media_variants = extract_story_media_variants_from_item(item)
        selected_variant = choose_primary_story_media_variant(variants: media_variants)
        media_type = selected_variant[:media_type].to_s.presence || story_media_type(item["media_type"])
        image_url = selected_variant[:image_url].to_s.presence
        video_url = selected_variant[:video_url].to_s.presence
        media_url = selected_variant[:media_url].to_s.presence || video_url.presence || image_url.presence
        width = selected_variant[:width]
        height = selected_variant[:height]
        owner_id = (item.dig("owner", "id") || item.dig("owner", "pk") || item.dig("user", "id") || item.dig("user", "pk")).to_s.strip
        owner_username = normalize_username(item.dig("user", "username").to_s)
        external_story_ctx = detect_external_story_attribution_from_item(
          item: item,
          reel_owner_id: reel_owner_id.to_s.presence || owner_id,
          reel_username: username
        )

        {
          story_id: story_id,
          media_type: media_type,
          media_url: media_url.presence || image_url.presence || video_url.presence,
          image_url: image_url.presence,
          video_url: video_url.presence,
          can_reply: item.key?("can_reply") ? ActiveModel::Type::Boolean.new.cast(item["can_reply"]) : nil,
          can_reshare: item.key?("can_reshare") ? ActiveModel::Type::Boolean.new.cast(item["can_reshare"]) : nil,
          owner_user_id: owner_id.presence,
          owner_username: owner_username.presence,
          api_has_external_profile_indicator: external_story_ctx[:has_external_profile_indicator],
          api_external_profile_reason: external_story_ctx[:reason_code],
          api_external_profile_targets: external_story_ctx[:targets],
          api_should_skip: external_story_ctx[:has_external_profile_indicator],
          api_raw_media_type: item["media_type"].to_i,
          primary_media_source: selected_variant[:source].to_s.presence,
          primary_media_index: selected_variant[:index],
          media_variants: media_variants,
          carousel_media: media_variants.select { |entry| entry[:source].to_s == "carousel_media" },
          width: width.to_i.positive? ? width.to_i : nil,
          height: height.to_i.positive? ? height.to_i : nil,
          caption: item.dig("caption", "text").to_s.presence,
          taken_at: parse_unix_time(item["taken_at"] || item["taken_at_timestamp"]),
          expiring_at: parse_unix_time(item["expiring_at"] || item["expiring_at_timestamp"]),
          permalink: "#{INSTAGRAM_BASE_URL}/stories/#{username}/#{story_id}/"
        }
      rescue StandardError
        nil
      end

      def extract_story_media_variants_from_item(item)
        return [] unless item.is_a?(Hash)

        variants = []
        variants << build_story_media_variant(item: item, source: "root", index: 0)
        Array(item["carousel_media"]).each_with_index do |entry, idx|
          variants << build_story_media_variant(item: entry, source: "carousel_media", index: idx + 1)
        end
        variants.compact.select { |entry| entry[:media_url].to_s.present? }
      rescue StandardError
        []
      end

      def build_story_media_variant(item:, source:, index:)
        return nil unless item.is_a?(Hash)

        media_type = story_media_type(item["media_type"])
        image_candidate = item.dig("image_versions2", "candidates", 0)
        video_candidate = Array(item["video_versions"]).first
        image_url = normalize_story_media_url(CGI.unescapeHTML(image_candidate&.dig("url").to_s).strip)
        video_url = normalize_story_media_url(CGI.unescapeHTML(video_candidate&.dig("url").to_s).strip)
        media_url = media_type == "video" ? (video_url.presence || image_url.presence) : (image_url.presence || video_url.presence)
        width = item["original_width"] || image_candidate&.dig("width") || video_candidate&.dig("width")
        height = item["original_height"] || image_candidate&.dig("height") || video_candidate&.dig("height")

        {
          source: source.to_s,
          index: index.to_i,
          media_pk: (item["pk"] || item["id"]).to_s.split("_").first.to_s.presence,
          raw_media_type: item["media_type"].to_i,
          media_type: media_type,
          media_url: media_url.to_s.presence,
          image_url: image_url,
          video_url: video_url,
          width: width.to_i.positive? ? width.to_i : nil,
          height: height.to_i.positive? ? height.to_i : nil
        }
      rescue StandardError
        nil
      end

      def choose_primary_story_media_variant(variants:)
        list = Array(variants).select { |entry| entry.is_a?(Hash) && entry[:media_url].to_s.present? }
        return {} if list.empty?

        root = list.find { |entry| entry[:source].to_s == "root" }
        return root if root

        video = list.find { |entry| entry[:media_type].to_s == "video" }
        return video if video

        list.first
      rescue StandardError
        {}
      end

      def normalize_story_media_url(url)
        value = url.to_s.strip
        return nil if value.blank?
        return value if value.start_with?("http://", "https://")
        return nil if value.start_with?("data:")
        return nil if value.match?(/\A[a-z][a-z0-9+\-.]*:/i)

        URI.join(INSTAGRAM_BASE_URL, value).to_s
      rescue URI::InvalidURIError, ArgumentError
        nil
      end

      def downloadable_story_media_url?(url)
        value = url.to_s.strip
        return false if value.blank?
        return false unless value.start_with?("http://", "https://")

        uri = URI.parse(value)
        uri.is_a?(URI::HTTP) || uri.is_a?(URI::HTTPS)
      rescue URI::InvalidURIError, ArgumentError
        false
      end

      def compact_story_media_variants_for_metadata(variants, limit: 8)
        Array(variants).first(limit.to_i.clamp(1, 20)).filter_map do |entry|
          data = entry.is_a?(Hash) ? entry : {}
          source = data[:source] || data["source"]
          media_type = data[:media_type] || data["media_type"]
          media_url = data[:media_url] || data["media_url"]
          next nil if media_url.to_s.blank?

          {
            source: source.to_s.presence,
            index: data[:index] || data["index"],
            media_pk: (data[:media_pk] || data["media_pk"]).to_s.presence,
            media_type: media_type.to_s.presence,
            media_url: media_url.to_s.presence,
            image_url: (data[:image_url] || data["image_url"]).to_s.presence,
            video_url: (data[:video_url] || data["video_url"]).to_s.presence,
            width: data[:width] || data["width"],
            height: data[:height] || data["height"]
          }.compact
        end
      rescue StandardError
        []
      end

      def detect_external_story_attribution_from_item(item:, reel_owner_id:, reel_username:)
        return { has_external_profile_indicator: false, reason_code: nil, targets: [] } unless item.is_a?(Hash)

        reasons = []
        targets = []
        normalized_owner_username = normalize_username(reel_username)

        owner_id = (item.dig("owner", "id") || item.dig("owner", "pk")).to_s.strip
        if owner_id.present? && reel_owner_id.to_s.present? && owner_id != reel_owner_id.to_s
          reasons << "owner_id_mismatch"
          targets << owner_id
        end

        story_feed_media = Array(item["story_feed_media"])
        if story_feed_media.any?
          sfm_targets = extract_story_feed_media_targets(story_feed_media)
          sfm_external_targets = sfm_targets.select do |target|
            external_story_target?(target, reel_owner_id: reel_owner_id, reel_username: normalized_owner_username)
          end
          if sfm_external_targets.any?
            reasons << "story_feed_media_external"
            targets.concat(sfm_external_targets)
          end
        end

        media_attribution_targets = extract_media_attribution_targets(Array(item["media_attributions_data"]))
        external_media_attribution_targets = media_attribution_targets.select do |target|
          external_story_target?(target, reel_owner_id: reel_owner_id, reel_username: normalized_owner_username)
        end
        if external_media_attribution_targets.any?
          reasons << "media_attributions_external"
          targets.concat(external_media_attribution_targets)
        end

        mention_targets = extract_reel_mention_targets(Array(item["reel_mentions"]))
        external_mention_targets = mention_targets.select do |target|
          external_story_target?(target, reel_owner_id: reel_owner_id, reel_username: normalized_owner_username)
        end
        if external_mention_targets.any?
          reasons << "reel_mentions_external"
          targets.concat(external_mention_targets)
        end

        reasons << "reshare_of_text_post" if item["is_reshare_of_text_post_app_media_in_ig"] == true

        owner_username = normalize_username(item.dig("user", "username").to_s)
        if owner_username.present? && normalized_owner_username.present? && owner_username != normalized_owner_username
          reasons << "owner_username_mismatch"
          targets << owner_username
        end

        reason_codes = reasons.uniq
        {
          has_external_profile_indicator: reason_codes.any?,
          reason_code: reason_codes.first,
          targets: targets.map(&:to_s).map(&:strip).reject(&:blank?).uniq.first(12)
        }
      rescue StandardError
        { has_external_profile_indicator: false, reason_code: nil, targets: [] }
      end

      def external_story_target?(target, reel_owner_id:, reel_username:)
        value = target.to_s.strip
        return false if value.blank?

        if value.match?(/\A\d+\z/)
          owner_id = reel_owner_id.to_s.strip
          return false if owner_id.blank?
          return value != owner_id
        end

        owner_username = normalize_username(reel_username)
        normalized_value = normalize_username(value)
        return false if owner_username.blank? || normalized_value.blank?

        normalized_value != owner_username
      rescue StandardError
        false
      end

      def extract_story_feed_media_targets(story_feed_media)
        Array(story_feed_media).filter_map do |entry|
          next unless entry.is_a?(Hash)

          media_owner_id = (
            entry.dig("media", "user", "id") ||
            entry.dig("media", "user", "pk") ||
            entry.dig("user", "id") ||
            entry.dig("user", "pk")
          ).to_s.strip
          next media_owner_id if media_owner_id.present?

          media_owner_username = normalize_username(
            entry.dig("media", "user", "username").to_s.presence ||
            entry.dig("user", "username").to_s
          )
          next media_owner_username if media_owner_username.present?

          compound = entry["media_compound_str"].to_s.strip
          next "" if compound.blank?
          next "" unless compound.include?("_")

          compound.split("_")[1].to_s.strip
        end.reject(&:blank?)
      rescue StandardError
        []
      end

      def extract_reel_mention_targets(reel_mentions)
        Array(reel_mentions).filter_map do |mention|
          next unless mention.is_a?(Hash)

          user_id = (mention.dig("user", "id") || mention.dig("user", "pk") || mention["user_id"]).to_s.strip
          next user_id if user_id.present?

          username = normalize_username(mention.dig("user", "username").to_s.presence || mention["username"].to_s)
          next username if username.present?

          nil
        end
      rescue StandardError
        []
      end

      def extract_media_attribution_targets(media_attributions_data)
        targets = []
        Array(media_attributions_data).each do |entry|
          collect_candidate_user_targets(entry, targets)
        end
        targets.map(&:to_s).map(&:strip).reject(&:blank?).uniq
      rescue StandardError
        []
      end

      def collect_candidate_user_targets(node, targets)
        return if node.nil?

        if node.is_a?(Array)
          node.each { |child| collect_candidate_user_targets(child, targets) }
          return
        end

        return unless node.is_a?(Hash)

        username_keys = %w[username owner_username mentioned_username]
        id_keys = %w[user_id owner_id mentioned_user_id pk id]

        username_keys.each do |key|
          value = normalize_username(node[key].to_s)
          targets << value if value.present?
        end
        id_keys.each do |key|
          value = node[key].to_s.strip
          targets << value if value.match?(/\A\d+\z/)
        end

        node.each_value { |child| collect_candidate_user_targets(child, targets) if child.is_a?(Hash) || child.is_a?(Array) }
      end

      def story_media_type(value)
        case value.to_i
        when 2 then "video"
        else "image"
        end
      end

      def debug_story_reel_data(referer_username:, user_id:, body:)
        begin
          # Create debug directory if it doesn't exist
          debug_dir = Rails.root.join("tmp", "story_reel_debug")
          FileUtils.mkdir_p(debug_dir) unless Dir.exist?(debug_dir)

          # Generate filename with timestamp
          timestamp = Time.current.strftime("%Y%m%d_%H%M%S_%L")
          filename = "#{referer_username}_reel_#{user_id}_#{timestamp}.json"
          filepath = File.join(debug_dir, filename)

          # Extract relevant debug information
          debug_data = {
            timestamp: Time.current.iso8601,
            referer_username: referer_username,
            user_id: user_id,
            raw_response: body,
            reels_count: body["reels"]&.keys&.size || 0,
            reels_media_count: body["reels_media"]&.size || 0,
            items_count: extract_items_count_from_body(body)
          }

          # Write debug data to file
          File.write(filepath, JSON.pretty_generate(debug_data))

          # Log the debug file creation
          Rails.logger.info "[STORY_REEL_DEBUG] Debug data saved: #{filepath}"

        rescue StandardError => e
          Rails.logger.error "[STORY_REEL_DEBUG] Failed to capture debug data: #{e.message}"
          # Don't fail the entire request if debug capture fails
        end
      end

      def extract_items_count_from_body(body)
        items = []
      
        if body["reels"].is_a?(Hash)
          body["reels"].each do |reel_id, reel_data|
            if reel_data.is_a?(Hash) && reel_data["items"].is_a?(Array)
              items.concat(reel_data["items"])
            end
          end
        end
      
        if body["reels_media"].is_a?(Array)
          body["reels_media"].each do |reel_data|
            if reel_data.is_a?(Hash) && reel_data["items"].is_a?(Array)
              items.concat(reel_data["items"])
            end
          end
        end
      
        items.size
      end

      def reel_entry_owner_id(entry)
        return "" unless entry.is_a?(Hash)

        (
          entry.dig("user", "id") ||
          entry.dig("user", "pk") ||
          entry.dig("owner", "id") ||
          entry.dig("owner", "pk") ||
          entry["id"] ||
          entry["pk"]
        ).to_s.strip
      rescue StandardError
        ""
      end

      def extract_post_for_analysis(item, comments_limit:, referer_username:)
        return nil unless item.is_a?(Hash)

        media_type = item["media_type"].to_i
        product_type = item["product_type"].to_s.downcase
        post_kind = product_type.include?("clips") ? "reel" : "post"
        is_repost =
          ActiveModel::Type::Boolean.new.cast(item["is_repost"]) ||
          item.dig("reshared_content", "pk").present? ||
          item["reshare_count"].to_i.positive?
        image_url = nil
        video_url = nil

        if media_type == 1
          image_url = item.dig("image_versions2", "candidates", 0, "url").to_s
        elsif media_type == 2
          video_url = Array(item["video_versions"]).first&.dig("url").to_s
          image_url = item.dig("image_versions2", "candidates", 0, "url").to_s
        elsif media_type == 8
          carousel = Array(item["carousel_media"]).select { |m| m.is_a?(Hash) }
          vid = carousel.find { |m| m["media_type"].to_i == 2 }
          img = carousel.find { |m| m["media_type"].to_i == 1 }
          video_url = Array(vid&.dig("video_versions")).first&.dig("url").to_s
          image_url = vid&.dig("image_versions2", "candidates", 0, "url").to_s.presence || img&.dig("image_versions2", "candidates", 0, "url").to_s
        else
          return nil
        end

        image_url = CGI.unescapeHTML(image_url).strip
        video_url = CGI.unescapeHTML(video_url).strip
        media_url = video_url.presence || image_url.presence
        return nil if media_url.blank?

        media_pk = item["pk"].presence || item["id"].to_s.split("_").first
        comments = fetch_media_comments(media_id: media_pk, referer_username: referer_username, count: comments_limit)
        comments = extract_preview_comments(item, comments_limit: comments_limit) if comments.empty?

        taken_at = parse_unix_time(item["taken_at"])
        shortcode = (item["code"] || item["shortcode"]).to_s.strip.presence
        permalink = shortcode.present? ? "#{INSTAGRAM_BASE_URL}/p/#{shortcode}/" : nil

        {
          shortcode: shortcode,
          media_id: media_pk.to_s.presence,
          post_kind: post_kind,
          product_type: product_type.presence,
          is_repost: is_repost,
          taken_at: taken_at,
          caption: item.dig("caption", "text").to_s.presence,
          media_url: media_url,
          image_url: image_url,
          video_url: video_url.presence,
          media_type: media_type,
          permalink: permalink,
          likes_count: item["like_count"].to_i,
          comments_count: item["comment_count"].to_i,
          comments: comments
        }
      rescue StandardError
        nil
      end

      def extract_preview_comments(item, comments_limit:)
        Array(item["preview_comments"]).first(comments_limit).map do |c|
          {
            author_username: c.is_a?(Hash) ? c.dig("user", "username").to_s.strip : nil,
            text: c.is_a?(Hash) ? c["text"].to_s : nil,
            created_at: parse_unix_time(c.is_a?(Hash) ? c["created_at"] : nil)
          }
        end
      end

      def fetch_media_comments(media_id:, referer_username:, count:)
        return [] if media_id.to_s.blank?

        uri = URI.parse("#{INSTAGRAM_BASE_URL}/api/v1/media/#{media_id}/comments/?can_support_threading=true&permalink_enabled=true")

        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = (uri.scheme == "https")
        http.open_timeout = 10
        http.read_timeout = 20

        req = Net::HTTP::Get.new(uri.request_uri)
        req["User-Agent"] = @account.user_agent.presence || "Mozilla/5.0"
        req["Accept"] = "application/json, text/plain, */*"
        req["X-Requested-With"] = "XMLHttpRequest"
        req["X-IG-App-ID"] = (@account.auth_snapshot.dig("ig_app_id").presence || "936619743392459")
        req["Referer"] = "#{INSTAGRAM_BASE_URL}/#{referer_username}/"

        csrf = @account.cookies.find { |c| c["name"].to_s == "csrftoken" }&.dig("value").to_s
        req["X-CSRFToken"] = csrf if csrf.present?
        req["Cookie"] = cookie_header_for(@account.cookies)

        res = http.request(req)
        return [] unless res.is_a?(Net::HTTPSuccess)
        return [] unless res["content-type"].to_s.include?("json")

        body = JSON.parse(res.body.to_s)
        items = Array(body["comments"]).first(count.to_i.clamp(1, 50))
        items.map do |c|
          {
            author_username: c.dig("user", "username").to_s.strip.presence,
            text: c["text"].to_s,
            created_at: parse_unix_time(c["created_at"])
          }
        end
      rescue StandardError
        []
      end

      def enrich_missing_post_comments_via_browser!(username:, posts:, comments_limit:)
        target_posts = Array(posts).select do |post|
          post.is_a?(Hash) &&
            post[:media_id].to_s.present? &&
            post[:comments_count].to_i.positive? &&
            Array(post[:comments]).empty?
        end
        return if target_posts.empty?

        with_recoverable_session(label: "profile_analysis_comments_fallback") do
          with_authenticated_driver do |driver|
            driver.navigate.to("#{INSTAGRAM_BASE_URL}/#{username}/")
            wait_for(driver, css: "body", timeout: 10)
            dismiss_common_overlays!(driver)

            target_posts.each do |post|
              comments = fetch_media_comments_from_browser_context(
                driver: driver,
                media_id: post[:media_id],
                count: comments_limit
              )
              next if comments.empty?

              post[:comments] = comments
            rescue StandardError
              next
            end
          end
        end
      rescue StandardError
        nil
      end

      def fetch_media_comments_from_browser_context(driver:, media_id:, count:)
        payload =
          driver.execute_async_script(
            <<~JS,
              const mediaId = arguments[0];
              const limit = arguments[1];
              const done = arguments[arguments.length - 1];

              fetch(`/api/v1/media/${mediaId}/comments/?can_support_threading=true&permalink_enabled=true`, {
                method: "GET",
                credentials: "include",
                headers: {
                  "Accept": "application/json, text/plain, */*",
                  "X-Requested-With": "XMLHttpRequest"
                }
              })
                .then(async (resp) => {
                  const text = await resp.text();
                  done({
                    ok: resp.ok,
                    status: resp.status,
                    content_type: resp.headers.get("content-type") || "",
                    body: text
                  });
                })
                .catch((err) => {
                  done({ ok: false, status: 0, content_type: "", body: "", error: String(err) });
                });
            JS
            media_id.to_s,
            count.to_i.clamp(1, 50)
          )

        return [] unless payload.is_a?(Hash)
        return [] unless payload["ok"] == true
        return [] unless payload["content_type"].to_s.include?("json")

        body = JSON.parse(payload["body"].to_s)
        items = Array(body["comments"]).first(count.to_i.clamp(1, 50))
        items.map do |c|
          {
            author_username: c.dig("user", "username").to_s.strip.presence,
            text: c["text"].to_s,
            created_at: parse_unix_time(c["created_at"])
          }
        end
      rescue StandardError
        []
      end
    end
  end
end
