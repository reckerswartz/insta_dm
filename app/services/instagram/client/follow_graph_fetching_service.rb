module Instagram
  class Client
    module FollowGraphFetchingService
    def sync_follow_graph!
      SyncFollowGraphService.new(
        account: @account,
        with_recoverable_session: method(:with_recoverable_session),
        with_authenticated_driver: method(:with_authenticated_driver),
        collect_conversation_users: method(:collect_conversation_users),
        collect_story_users: method(:collect_story_users),
        collect_follow_list: method(:collect_follow_list),
        upsert_follow_list: method(:upsert_follow_list!)
      ).call
    end

    def fetch_mutual_friends(profile_username:, limit: 36)
      max_results = limit.to_i.clamp(1, 100)
      fetch_mutual_friends_via_api(profile_username: profile_username, limit: max_results)
    rescue StandardError => e
      Rails.logger.warn("Instagram fetch_mutual_friends failed for #{profile_username}: #{e.class}: #{e.message}")
      []
    end

    def collect_follow_list(driver, list_kind:, profile_username:)
      meta = { list_kind: list_kind.to_s, profile_username: profile_username }

      with_task_capture(driver: driver, task_name: "sync_collect_#{list_kind}", meta: meta) do
        api_users = fetch_follow_list_via_api(profile_username: profile_username, list_kind: list_kind)
        if api_users.present?
          meta[:source] = "api_friendships"
          meta[:unique_usernames] = api_users.length
          return api_users
        end

        meta[:source] = "html_fallback"
        list_path = (list_kind == :followers) ? "followers" : "following"
        list_url = "#{INSTAGRAM_BASE_URL}/#{profile_username}/#{list_path}/"
        profile_url = "#{INSTAGRAM_BASE_URL}/#{profile_username}/"

        meta[:list_url] = list_url
        meta[:profile_url] = profile_url

        dialog =
          begin
            meta[:open_strategy] = "direct_url"
            driver.navigate.to(list_url)
            wait_for(driver, css: "body", timeout: 12)
            dismiss_common_overlays!(driver)
            wait_for(driver, css: "div[role='dialog']", timeout: 12)
          rescue Selenium::WebDriver::Error::TimeoutError
            nil
          end

        unless dialog
          # Fallback for builds that don't open the modal on the /followers/ route until after profile renders.
          meta[:open_strategy] = "profile_click_fallback"
          driver.navigate.to(profile_url)
          wait_for(driver, css: "body", timeout: 12)
          dismiss_common_overlays!(driver)

          href_fragment = "/#{list_path}/"

          # Some profiles render counts lazily; wait briefly for the link to appear.
          begin
            Selenium::WebDriver::Wait.new(timeout: 12).until do
              driver.execute_script(<<~JS, href_fragment)
                const frag = arguments[0];
                const els = Array.from(document.querySelectorAll("a[href]"));
                return els.some((a) => (a.getAttribute("href") || "").includes(frag));
              JS
            end
          rescue Selenium::WebDriver::Error::TimeoutError
            nil
          end

          clicked = false
          attempts = 0
          8.times do
            attempts += 1
            begin
              clicked = driver.execute_script(<<~JS, href_fragment)
                const frag = arguments[0];
                const candidates = Array.from(document.querySelectorAll(`a[href*="${frag}"]`));
                if (!candidates.length) return false;

                const isVisible = (el) => {
                  const r = el.getBoundingClientRect();
                  const cs = window.getComputedStyle(el);
                  return cs && cs.visibility !== "hidden" && cs.display !== "none" && r.width > 0 && r.height > 0;
                };

                const link = candidates.find(isVisible) || candidates[0];
                try { link.scrollIntoView({block: "center", inline: "nearest"}); } catch (e) {}
                try { link.click(); return true; } catch (e) {}
                try { link.dispatchEvent(new MouseEvent("click", {bubbles: true, cancelable: true, view: window})); return true; } catch (e) {}
                return false;
              JS
            rescue Selenium::WebDriver::Error::StaleElementReferenceError,
                   Selenium::WebDriver::Error::JavascriptError,
                   Selenium::WebDriver::Error::ElementClickInterceptedError,
                   Selenium::WebDriver::Error::ElementNotInteractableError
              clicked = false
            end

            break if clicked
            sleep(0.35)
          end
          meta[:profile_link_click_attempts] = attempts

          raise "Unable to find #{list_kind} link on profile" unless clicked

          dialog = wait_for(driver, css: "div[role='dialog']", timeout: 12)
        end

        if (counts = extract_profile_follow_counts(driver.page_source.to_s))
          meta[:expected_followers] = counts[:followers]
          meta[:expected_following] = counts[:following]
          meta[:expected_count] = (list_kind == :followers) ? counts[:followers] : counts[:following]
        end

        # The dialog often opens in a skeleton/loading state; if we start extracting immediately we'll
        # see 0 usernames and prematurely terminate. Wait briefly for at least one profile row anchor.
        begin
          Selenium::WebDriver::Wait.new(timeout: 20).until do
            driver.execute_script(<<~'JS')
              const dialog = document.querySelector("div[role='dialog']");
              if (!dialog) return false;
              const anchors = Array.from(dialog.querySelectorAll("a[href^='/']"));
              return anchors.some((a) => {
                const href = (a.getAttribute("href") || "").trim();
                return /^\/[A-Za-z0-9._]{1,30}\/(?:\?.*)?$/.test(href);
              });
            JS
          end
        rescue Selenium::WebDriver::Error::TimeoutError
          # We'll still attempt extraction; capture will show the loading state HTML.
        end

        users = {}
        stable_rounds = 0
        last_count = 0
        stuck_rounds = 0
        last_scroll_top = nil

        max_rounds = (list_kind == :following) ? 750 : 260

        max_rounds.times do
          payload = driver.execute_script(<<~'JS')
            const dialog = document.querySelector("div[role='dialog']");
            if (!dialog) return { out: [], scrolled: false, dialog_found: false };

            const out = [];
            const anchors = Array.from(dialog.querySelectorAll("a[href^='/']"));
            for (const a of anchors) {
              const href = (a.getAttribute("href") || "").trim();
              const m = href.match(/^\/([A-Za-z0-9._]{1,30})\/(?:\?.*)?$/);
              if (!m) continue;

              const username = (m[1] || "").toLowerCase();
              if (!username) continue;

              // Exclude common non-profile routes that can appear in dialogs.
              const reserved = new Set(["accounts","explore","direct","p","reel","reels","stories","about","privacy","terms"]);
              if (reserved.has(username)) continue;

              const row = a.closest("div");
              const img = row ? row.querySelector("img") : null;
              const pic = img ? (img.getAttribute("src") || "") : "";
              const alt = img ? (img.getAttribute("alt") || "") : "";

              // Display name is often in a sibling span; best-effort only.
              let display = "";
              if (row) {
                const spans = Array.from(row.querySelectorAll("span")).map((s) => (s.textContent || "").trim()).filter(Boolean);
                // Username is typically present; choose a non-username candidate if possible.
                display = spans.find((t) => t.toLowerCase() !== username) || "";
              }

              if (!display && alt) {
                // Common patterns: "Full Name's profile picture" or "Profile picture"
                const cleaned = alt
                  .replace(/'s profile picture/gi, "")
                  .replace(/profile picture/gi, "")
                  .trim();
                if (cleaned && cleaned.toLowerCase() !== username) display = cleaned;
              }

              out.push({ username: username, display_name: display, profile_pic_url: pic });
            }

            // Scroll the modal list to load more entries.
            // IG sometimes places the actual scroll container on a nested node, and not always a div.
            // Choose the scrollable element that contains the most profile-link anchors.
            const allNodes = Array.from(dialog.querySelectorAll("*"));
            const scrollables = allNodes.filter((el) => {
              try { return (el.scrollHeight - el.clientHeight) > 180; } catch (e) { return false; }
            });
            const scoreScroller = (el) => {
              let links = 0;
              try {
                const anchors = Array.from(el.querySelectorAll("a[href^='/']"));
                for (const a of anchors) {
                  const href = (a.getAttribute("href") || "").trim();
                  if (/^\/[A-Za-z0-9._]{1,30}\/(?:\?.*)?$/.test(href)) links += 1;
                }
              } catch (e) {}
              let sh = 0;
              try { sh = el.scrollHeight || 0; } catch (e) {}
              return { links: links, sh: sh };
            };
            let scroller = null;
            let best = { links: -1, sh: -1 };
            for (const el of scrollables) {
              const s = scoreScroller(el);
              // Prefer the largest scrollHeight; it tends to represent the "true" list scroller.
              if (s.sh > best.sh || (s.sh === best.sh && s.links > best.links)) {
                best = s;
                scroller = el;
              }
            }
            scroller = scroller || dialog;
            let before = 0;
            try { before = scroller.scrollTop || 0; } catch (e) {}
            try { scroller.scrollTop = before + scroller.clientHeight * 0.95; } catch (e) {}
            // If the computed scroller doesn't move, try a scrollBy fallback.
            try {
              if ((scroller.scrollTop || 0) === before) scroller.scrollBy(0, Math.max(120, scroller.clientHeight || 0));
            } catch (e) {}

            let after = before;
            let sh = 0;
            let ch = 0;
            try { after = scroller.scrollTop || after; } catch (e) {}
            try { sh = scroller.scrollHeight || 0; } catch (e) {}
            try { ch = scroller.clientHeight || 0; } catch (e) {}
            const at_end = (ch > 0) ? ((after + ch) >= (sh - 4)) : false;
            const did_scroll = after !== before;

            const loading = !!dialog.querySelector("[role='progressbar'], svg[aria-label='Loading...'], div[data-visualcompletion='loading-state']");

            return {
              out: out,
              scrolled: true,
              dialog_found: true,
              scroll_top: after,
              scroll_height: sh,
              client_height: ch,
              at_end: at_end,
              did_scroll: did_scroll,
              scroller_score: best,
              scrollers_seen: scrollables.length,
              loading: loading
            };
          JS

          unless payload.is_a?(Hash) && (payload["dialog_found"] == true || payload[:dialog_found] == true)
            # If the modal was replaced/closed due to navigation, stop early.
            break
          end

          batch = payload["out"] || payload[:out] || []
          at_end = payload["at_end"] == true || payload[:at_end] == true
          did_scroll = payload["did_scroll"] == true || payload[:did_scroll] == true
          loading = payload["loading"] == true || payload[:loading] == true
          scroll_top = payload["scroll_top"] || payload[:scroll_top]
          scroller_score = payload["scroller_score"] || payload[:scroller_score]
          scrollers_seen = payload["scrollers_seen"] || payload[:scrollers_seen]

          Array(batch).each do |entry|
            u = normalize_username(entry["username"] || entry[:username])
            next if u.blank?

            users[u] ||= {
              display_name: (entry["display_name"] || entry[:display_name]).presence,
              profile_pic_url: (entry["profile_pic_url"] || entry[:profile_pic_url]).presence
            }
          end

          if users.length == last_count
            stable_rounds += 1
          else
            stable_rounds = 0
            last_count = users.length
          end

          if scroll_top
            if last_scroll_top && scroll_top.to_f <= (last_scroll_top.to_f + 1.0)
              stuck_rounds += 1
            else
              stuck_rounds = 0
            end
            last_scroll_top = scroll_top
          end

          meta[:scroll_top] = scroll_top
          meta[:scroll_stuck_rounds] = stuck_rounds
          meta[:stable_rounds] = stable_rounds
          meta[:at_end] = at_end
          meta[:did_scroll] = did_scroll
          meta[:loading] = loading
          meta[:scroller_score] = scroller_score if scroller_score
          meta[:scrollers_seen] = scrollers_seen if scrollers_seen

          expected_count = meta[:expected_count].to_i
          if expected_count.positive? && users.length >= expected_count
            break
          end

          # If the modal is still loading and we haven't found anyone yet, keep waiting instead of
          # tripping the stable_rounds safety breaker.
          if users.empty? && loading
            stable_rounds = 0
            sleep(0.75)
            next
          end

          # If we never actually scroll, IG likely swapped/locked the scroll container.
          # Reset stable counter to allow more time and let subsequent iterations re-select the scroller.
          unless did_scroll
            stable_rounds = 0 if stable_rounds < 4
          end

          # Break only once we hit the end of the scroll region and nothing new has loaded for a bit.
          far_from_expected =
            expected_count.positive? && users.length < (expected_count * 0.98).floor

          break if at_end && stable_rounds >= 3 && !far_from_expected

          break if (stuck_rounds >= 25) && !far_from_expected
          break if (stable_rounds >= 60) && !far_from_expected

          sleep(
            if loading
              0.8
            elsif stable_rounds >= 10
              1.15
            elsif stable_rounds >= 3
              0.8
            else
              0.4
            end
          )
        end

        meta[:unique_usernames] = users.length

        begin
          driver.action.send_keys(:escape).perform
        rescue StandardError
          nil
        end

        users
      end
    end

    def upsert_follow_list!(users_hash, following_flag:, follows_you_flag:)
      now = Time.current

      users_hash.each do |username, attrs|
        profile = @account.instagram_profiles.find_or_initialize_by(username: username)

        # If we already have a profile_pic_url, keep it unless we received a new one.
        new_pic = attrs.dig(:profile_pic_url).presence
        profile.profile_pic_url = new_pic if new_pic.present?

        new_display = attrs.dig(:display_name).presence
        profile.display_name = new_display if new_display.present?

        profile.following = true if following_flag
        profile.follows_you = true if follows_you_flag
        profile.last_synced_at = now
        profile.save!
      end
    end

    def fetch_follow_list_via_api(profile_username:, list_kind:)
      uname = normalize_username(profile_username)
      return {} if uname.blank?

      web_info = fetch_web_profile_info(uname)
      user = web_info.is_a?(Hash) ? web_info.dig("data", "user") : nil
      user_id = user.is_a?(Hash) ? user["id"].to_s.strip : ""
      return {} if user_id.blank?

      endpoint = (list_kind.to_sym == :followers) ? "followers" : "following"
      max_id = nil
      users = {}
      safety = 0

      loop do
        safety += 1
        break if safety > 25

        query = [ "count=200" ]
        query << "max_id=#{CGI.escape(max_id)}" if max_id.present?
        path = "/api/v1/friendships/#{user_id}/#{endpoint}/?#{query.join('&')}"
        body = ig_api_get_json(path: path, referer: "#{INSTAGRAM_BASE_URL}/#{uname}/")
        break unless body.is_a?(Hash)

        Array(body["users"]).each do |entry|
          next unless entry.is_a?(Hash)
          username = normalize_username(entry["username"])
          next if username.blank?

          users[username] ||= {
            display_name: entry["full_name"].to_s.strip.presence || username,
            profile_pic_url: CGI.unescapeHTML(entry["profile_pic_url"].to_s).strip.presence
          }
        end

        max_id = body["next_max_id"].to_s.strip.presence
        break if max_id.blank?
      end

      users
    rescue StandardError
      {}
    end

    def fetch_mutual_friends_via_api(profile_username:, limit:)
      uname = normalize_username(profile_username)
      return [] if uname.blank?

      web_info = fetch_web_profile_info(uname)
      user = web_info.is_a?(Hash) ? web_info.dig("data", "user") : nil
      user_id = user.is_a?(Hash) ? user["id"].to_s.strip : ""
      return [] if user_id.blank?

      max_results = limit.to_i.clamp(1, 100)
      max_id = nil
      safety = 0
      mutuals = []
      seen_usernames = Set.new

      loop do
        break if mutuals.length >= max_results
        safety += 1
        break if safety > 25

        query = [ "count=#{[max_results, 200].min}" ]
        query << "max_id=#{CGI.escape(max_id)}" if max_id.present?

        # Use the dedicated mutual friends endpoint
        path = "/api/v1/friendships/#{user_id}/mutual_friends/?#{query.join('&')}"
        body = ig_api_get_json(path: path, referer: "#{INSTAGRAM_BASE_URL}/#{uname}/")
        break unless body.is_a?(Hash)

        users = Array(body["users"]).select { |entry| entry.is_a?(Hash) }
        break if users.empty?

        users.each do |entry|
          username = normalize_username(entry["username"])
          next if username.blank? || seen_usernames.include?(username)

          seen_usernames << username
          mutuals << {
            username: username,
            display_name: entry["full_name"].to_s.strip.presence || username,
            profile_pic_url: CGI.unescapeHTML(entry["profile_pic_url"].to_s).strip.presence
          }
          break if mutuals.length >= max_results
        end

        max_id = body["next_max_id"].to_s.strip.presence
        break if max_id.blank?
      end

      mutuals
    rescue StandardError
      []
    end
    end
  end
end
