module Instagram
  class Client
    module StoryNavigationSupport
      private

      def story_viewer_ready?(dom)
        dom.is_a?(Hash) && dom[:story_viewer_active]
      end

      def find_home_story_open_target(driver, excluded_usernames: [])
        # First, try to capture the current page state for debugging
        page_debug = driver.execute_script(<<~JS)
          return {
            url: window.location.href,
            title: document.title,
            storyLinks: document.querySelectorAll("a[href*='/stories/']").length,
            storyButtons: document.querySelectorAll("[aria-label*='story' i]").length,
            allButtons: document.querySelectorAll("button, [role='button']").length,
            allLinks: document.querySelectorAll("a").length,
            bodyText: document.body.innerText.slice(0, 500),
            hasStoryTray: !!document.querySelector('[data-testid*="story"], [class*="story"], [id*="story"]')
          };
        JS

        payload = driver.execute_script(<<~JS, excluded_usernames, page_debug)
          const excluded = Array.isArray(arguments[0]) ? arguments[0].map((u) => (u || "").toString().toLowerCase()).filter(Boolean) : [];
          const isVisible = (el) => {
            if (!el) return false;
            const s = window.getComputedStyle(el);
            if (!s || s.display === "none" || s.visibility === "hidden" || s.opacity === "0" || s.pointerEvents === "none") return false;
            const r = el.getBoundingClientRect();
            return r.width > 5 && r.height > 5 && r.bottom > 0 && r.right > 0;
          };
          const isExcluded = (text, href) => excluded.some((u) => text.includes(u) || href.includes(`/${u}/`));

          const candidates = [];
          const add = (el, strategy) => {
            if (!el) return;
            try {
              if (!isVisible(el)) return;
              const r = el.getBoundingClientRect();
              const topZone = r.top >= 0 && r.top < Math.max(760, window.innerHeight * 0.85);
              if (!topZone) return;
              const text = (el.getAttribute("aria-label") || el.textContent || "").toLowerCase();
              const href = (el.getAttribute("href") || "").toLowerCase();
              const liveHost = el.closest("a[href*='/live/'], [href*='/live/']");
              if (text.includes("your story")) return;
              if (text.includes("live") || href.includes("/live/") || liveHost) return;
              if (isExcluded(text, href)) return;
              candidates.push({ el, strategy, top: r.top, left: r.left, w: r.width, h: r.height, text: text.slice(0, 50), href: href.slice(0, 50) });
            } catch (e) {
              // Skip problematic elements
            }
          };

          // Aggressive story detection with multiple fallback strategies
          document.querySelectorAll("a[href*='/stories/']").forEach((el) => add(el, "href_story_link"));
          document.querySelectorAll("button[aria-label*='story' i], [role='button'][aria-label*='story' i], a[aria-label*='story' i]").forEach((el) => add(el, "aria_story_button"));
          document.querySelectorAll("[data-testid*='story'], [class*='story'], [id*='story']").forEach((container) => {
            try {
              container.querySelectorAll("a, button, [role='button'], [class*='avatar'], [class*='profile']").forEach((el) => add(el, "container_story_element"));
            } catch (e) {}
          });

          // Ultra-fallback: any clickable element that might be a story
          if (candidates.length === 0) {
            document.querySelectorAll("a[href*='/'], button, [role='button']").forEach((el) => {
              try {
                const text = (el.getAttribute("aria-label") || el.textContent || "").toLowerCase();
                const href = (el.getAttribute("href") || "").toLowerCase();
                if (text.includes("story") || href.includes("story") || (text && text.length > 0 && text.length < 50)) {
                  add(el, "ultra_fallback");
                }
              } catch (e) {}
            });
          }

          candidates.sort((a, b) => (a.top - b.top) || (a.left - b.left));
          const chosen = candidates[0];
          if (!chosen) return { found: false, count: 0, strategy: "none", debug: { candidates: candidates.length, totalStoryLinks: document.querySelectorAll("a[href*='/stories/']").length, totalStoryButtons: document.querySelectorAll("[aria-label*='story' i]").length, pageDebug: arguments[1] } };

          try { chosen.el.setAttribute("data-codex-story-open", "1"); } catch (e) {}
          return { found: true, count: candidates.length, strategy: chosen.strategy, debug: { candidates: candidates.length, chosenStrategy: chosen.strategy, chosenText: chosen.text, chosenHref: chosen.href, pageDebug: arguments[1] } };
        JS

        el = nil
        if payload.is_a?(Hash) && payload["found"]
          begin
            el = driver.find_element(css: "[data-codex-story-open='1']")
          rescue StandardError
            el = nil
          end
        end

        {
          element: el,
          count: payload.is_a?(Hash) ? payload["count"].to_i : 0,
          strategy: payload.is_a?(Hash) ? payload["strategy"].to_s : "none",
          debug: payload.is_a?(Hash) ? payload["debug"] : {}
        }
      ensure
        begin
          driver.execute_script("const el=document.querySelector('[data-codex-story-open=\"1\"]'); if (el) el.removeAttribute('data-codex-story-open');")
        rescue StandardError
          nil
        end
      end

      def detect_home_story_carousel_probe(driver, excluded_usernames: [])
        # Force capture page state on every probe for debugging
        page_debug = driver.execute_script(<<~JS)
          return {
            url: window.location.href,
            title: document.title,
            storyLinks: document.querySelectorAll("a[href*='/stories/']").length,
            storyButtons: document.querySelectorAll("[aria-label*='story' i]").length,
            allButtons: document.querySelectorAll("button, [role='button']").length,
            allLinks: document.querySelectorAll("a").length,
            bodyText: document.body.innerText.slice(0, 1000),
            hasStoryTray: !!document.querySelector('[data-testid*="story"], [class*="story"], [id*="story"]'),
            htmlLength: document.documentElement.outerHTML.length,
            readyState: document.readyState,
            visibleElements: Array.from(document.querySelectorAll('*')).filter(el => {
              try {
                const rect = el.getBoundingClientRect();
                return rect.width > 0 && rect.height > 0 && rect.top >= 0 && rect.top < window.innerHeight;
              } catch(e) { return false; }
            }).length
          };
        JS

        # Always capture debug info
        Rails.logger.info "Story carousel probe debug: #{page_debug.inspect}" if defined?(Rails)

        anchors = driver.find_elements(css: "a[href*='/stories/']")
        visible_anchor = anchors.find { |el| el.displayed? rescue false } || anchors.first
        target = find_home_story_open_target(driver, excluded_usernames: excluded_usernames)

        html = driver.page_source.to_s
        Rails.logger.info "HTML length: #{html.length}, contains stories pattern: #{html.include?('stories')}" if defined?(Rails)
        prefetch_users = extract_story_users_from_home_html(html)

        result = {
          anchor: visible_anchor,
          target: target[:element],
          target_count: target[:count].to_i,
          target_strategy: target[:strategy].to_s.presence || "none",
          anchor_count: anchors.length,
          prefetch_count: prefetch_users.length,
          prefetch_usernames: prefetch_users.take(12),
          debug: target[:debug] || {},
          page_debug: page_debug
        }

        Rails.logger.info "Carousel probe result: #{result.inspect}" if defined?(Rails)
        result
      rescue StandardError => e
        Rails.logger.error "Carousel probe error: #{e.message}" if defined?(Rails)
        { anchor: nil, target: nil, target_count: 0, target_strategy: "none", anchor_count: 0, prefetch_count: 0, prefetch_usernames: [], debug: { error: e.message } }
      end

      def click_home_story_open_target_via_js(driver, excluded_usernames: [])
        payload = driver.execute_script(<<~JS, excluded_usernames)
          const excluded = Array.isArray(arguments[0]) ? arguments[0].map((u) => (u || "").toString().toLowerCase()).filter(Boolean) : [];
          const isVisible = (el) => {
            if (!el) return false;
            const s = window.getComputedStyle(el);
            if (!s || s.display === "none" || s.visibility === "hidden" || s.pointerEvents === "none") return false;
            const r = el.getBoundingClientRect();
            return r.width > 18 && r.height > 18 && r.bottom > 0 && r.right > 0;
          };
          const isExcluded = (text, href) => excluded.some((u) => text.includes(u) || href.includes(`/${u}/`));

          const clickEl = (el) => {
            try { el.scrollIntoView({ block: "center", inline: "center" }); } catch (e) {}
            const evt = { view: window, bubbles: true, cancelable: true, composed: true, button: 0 };
            ["pointerdown", "mousedown", "mouseup", "click"].forEach((type) => {
              try { el.dispatchEvent(new MouseEvent(type, evt)); } catch (e) {}
            });
            try { el.click(); } catch (e) {}
            return true;
          };

          const candidates = [];
          const add = (el, strategy) => {
            if (!isVisible(el)) return;
            const r = el.getBoundingClientRect();
            const topZone = r.top >= 0 && r.top < Math.max(760, window.innerHeight * 0.85);
            if (!topZone) return;
            const text = (el.getAttribute("aria-label") || el.textContent || "").toLowerCase();
            const href = (el.getAttribute("href") || "").toLowerCase();
            const liveHost = el.closest("a[href*='/live/'], [href*='/live/']");
            if (text.includes("your story")) return;
            if (text.includes("live") || href.includes("/live/") || liveHost) return;
            if (isExcluded(text, href)) return;
            candidates.push({ el, strategy, top: r.top, left: r.left });
          };

          document.querySelectorAll("a[href*='/stories/']").forEach((el) => add(el, "href_story_link"));
          document.querySelectorAll("button[aria-label*='story' i], [role='button'][aria-label*='story' i], a[aria-label*='story' i]").forEach((el) => add(el, "aria_story_button"));

          candidates.sort((a, b) => (a.top - b.top) || (a.left - b.left));
          const chosen = candidates[0];
          if (!chosen) return { clicked: false, count: 0, strategy: "none" };

          clickEl(chosen.el);
          return { clicked: true, count: candidates.length, strategy: chosen.strategy };
        JS

        {
          clicked: payload.is_a?(Hash) && payload["clicked"] == true,
          count: payload.is_a?(Hash) ? payload["count"].to_i : 0,
          strategy: payload.is_a?(Hash) ? payload["strategy"].to_s : "none"
        }
      rescue StandardError
        { clicked: false, count: 0, strategy: "none" }
      end

      def open_story_from_prefetch_usernames(driver:, usernames:, attempts:, probe:)
        candidates = Array(usernames).map { |u| normalize_username(u) }.reject(&:blank?).uniq.take(8)
        return false if candidates.empty?

        candidates.each_with_index do |normalized, idx|
          begin
            driver.navigate.to("#{INSTAGRAM_BASE_URL}/stories/#{normalized}/")
            wait_for(driver, css: "body", timeout: 12)

            4.times do
              sleep(0.6)
              dom = extract_story_dom_context(driver)
              if story_viewer_ready?(dom)
                capture_task_html(
                  driver: driver,
                  task_name: "home_story_sync_first_story_opened_prefetch_route",
                  status: "ok",
                  meta: {
                    strategy: "prefetch_username_route",
                    username: normalized,
                    candidate_index: idx,
                    candidate_count: candidates.length,
                    attempts: attempts,
                    target_count: probe[:target_count],
                    anchor_count: probe[:anchor_count],
                    prefetch_story_usernames: probe[:prefetch_count]
                  }
                )
                return true
              end
            end
          rescue StandardError
            nil
          end
        end

        capture_task_html(
          driver: driver,
          task_name: "home_story_sync_first_story_opened_prefetch_route",
          status: "error",
          meta: {
            strategy: "prefetch_username_route",
            attempts: attempts,
            target_count: probe[:target_count],
            anchor_count: probe[:anchor_count],
            prefetch_story_usernames: probe[:prefetch_count],
            usernames_tried: candidates
          }
        )
        false
      end


      def current_story_context(driver)
        url = driver.current_url.to_s
        ref = current_story_reference(url)
        username = ref.to_s.split(":").first.to_s
        story_id = ref.to_s.split(":")[1].to_s
        dom = extract_story_dom_context(driver)

        if ref.blank? && dom[:og_story_url].present?
          ref = current_story_reference(dom[:og_story_url])
          username = ref.to_s.split(":").first.to_s if username.blank?
          story_id = ref.to_s.split(":")[1].to_s if story_id.blank?
        end

        recovery_needed = false
        if ref.blank?
          fallback_username = extract_username_from_profile_like_path(url)
          if fallback_username.present?
            username = fallback_username
            ref = "#{fallback_username}:#{story_id.presence || 'unknown'}"
            recovery_needed = dom[:story_viewer_active] && !dom[:story_frame_present]
          end
        end
        if dom[:story_viewer_active] && !dom[:story_frame_present]
          # Do not treat profile-preview-like pages as valid story context.
          ref = ""
          story_id = ""
        end
        username = dom[:meta_username].to_s if username.blank? && dom[:meta_username].present?

        media_signature = dom[:media_signature].to_s
        key = if username.present? && story_id.present?
          "#{username}:#{story_id}"
        elsif username.present? && media_signature.present?
          "#{username}:sig:#{media_signature}"
        else
          ref
        end

        {
          ref: ref,
          username: normalize_username(username),
          story_id: story_id,
          url: url,
          story_url_recovery_needed: recovery_needed,
          story_viewer_active: dom[:story_viewer_active],
          story_key: key,
          media_signature: media_signature
        }
      end

      def normalized_story_context_for_processing(driver:, context:)
        ctx = context.is_a?(Hash) ? context.dup : {}
        live_url = driver.current_url.to_s
        live_ref = current_story_reference(live_url)
        if live_ref.present?
          live_username = normalize_username(live_ref.to_s.split(":").first.to_s)
          live_story_id = normalize_story_id_token(live_ref.to_s.split(":")[1].to_s)
          ctx[:ref] = live_ref
          ctx[:username] = live_username if live_username.present?
          ctx[:story_id] = live_story_id if live_story_id.present?
        end

        ctx[:username] = normalize_username(ctx[:username])
        ctx[:story_id] = normalize_story_id_token(ctx[:story_id])
        if ctx[:username].present? && ctx[:story_id].present?
          ctx[:ref] = "#{ctx[:username]}:#{ctx[:story_id]}"
          ctx[:story_key] = "#{ctx[:username]}:#{ctx[:story_id]}"
        end
        ctx[:url] = canonical_story_url(username: ctx[:username], story_id: ctx[:story_id], fallback_url: live_url)
        ctx
      rescue StandardError
        context
      end

      def recover_story_url_context!(driver:, username:, reason:)
        clean_username = normalize_username(username)
        return if clean_username.blank?

        path = "#{INSTAGRAM_BASE_URL}/stories/#{clean_username}/"
        driver.navigate.to(path)
        wait_for(driver, css: "body", timeout: 12)
        dismiss_common_overlays!(driver)
        freeze_story_progress!(driver)
        capture_task_html(
          driver: driver,
          task_name: "home_story_sync_story_context_recovered",
          status: "ok",
          meta: {
            reason: reason,
            username: clean_username,
            current_url: driver.current_url.to_s
          }
        )
      rescue StandardError => e
        capture_task_html(
          driver: driver,
          task_name: "home_story_sync_story_context_recovery_failed",
          status: "error",
          meta: {
            reason: reason,
            username: clean_username,
            error_class: e.class.name,
            error_message: e.message
          }
        )
      end


      def visible_story_media_signature(driver)
        payload = driver.execute_script(<<~JS)
          const out = { media_signature: "", title: (document.title || "").toString() };
          const visible = (el) => {
            if (!el) return false;
            const style = window.getComputedStyle(el);
            if (!style || style.display === "none" || style.visibility === "hidden" || style.opacity === "0") return false;
            const r = el.getBoundingClientRect();
            return r.width > 120 && r.height > 120;
          };

          const mediaEl = Array.from(document.querySelectorAll("img,video")).find((el) => visible(el));
          const src = mediaEl ? (mediaEl.currentSrc || mediaEl.src || mediaEl.getAttribute("src") || "") : "";
          out.media_signature = [out.title, src].filter(Boolean).join("|").slice(0, 400);
          return out;
        JS

        payload.is_a?(Hash) ? payload["media_signature"].to_s : ""
      rescue StandardError
        ""
      end

      def extract_story_dom_context(driver)
        payload = driver.execute_script(<<~JS)
          const out = {
            og_story_url: "",
            meta_username: "",
            story_viewer_active: false,
            story_frame_present: false,
            media_signature: ""
          };
          const og = document.querySelector("meta[property='og:url']");
          const ogUrl = (og && og.content) ? og.content.toString() : "";
          if (ogUrl.includes("/stories/")) out.og_story_url = ogUrl;

          const path = window.location.pathname || "";
          if (path.includes("/stories/")) out.story_viewer_active = true;
          if ((document.title || "").toLowerCase().includes("story")) out.story_viewer_active = true;
          if (out.og_story_url) out.story_viewer_active = true;

          const match = out.og_story_url.match(/\\/stories\\/([A-Za-z0-9._]{1,30})/);
          if (match && match[1]) out.meta_username = match[1];

          const visible = (el) => {
            if (!el) return false;
            const style = window.getComputedStyle(el);
            if (!style || style.display === "none" || style.visibility === "hidden" || style.opacity === "0") return false;
            const r = el.getBoundingClientRect();
            return r.width > 120 && r.height > 120;
          };
          const mediaEl = Array.from(document.querySelectorAll("img,video")).find((el) => visible(el));
          const src = mediaEl ? (mediaEl.currentSrc || mediaEl.src || mediaEl.getAttribute("src") || "") : "";
          const rect = mediaEl ? mediaEl.getBoundingClientRect() : { width: 0, height: 0 };
          out.story_frame_present = Boolean(mediaEl && rect.width >= 220 && rect.height >= 220);
          out.media_signature = [document.title || "", src].filter(Boolean).join("|").slice(0, 400);
          return out;
        JS

        return {} unless payload.is_a?(Hash)

        {
          og_story_url: payload["og_story_url"].to_s,
          meta_username: payload["meta_username"].to_s,
          story_viewer_active: ActiveModel::Type::Boolean.new.cast(payload["story_viewer_active"]),
          story_frame_present: ActiveModel::Type::Boolean.new.cast(payload["story_frame_present"]),
          media_signature: payload["media_signature"].to_s
        }
      rescue StandardError
        { og_story_url: "", meta_username: "", story_viewer_active: false, story_frame_present: false, media_signature: "" }
      end



      def freeze_story_progress!(driver)
        driver.execute_script(<<~JS)
          const pauseStory = () => {
            try {
              document.querySelectorAll("video").forEach((v) => {
                try { v.pause(); } catch (e) {}
                try { v.playbackRate = 0; } catch (e) {}
              });
            } catch (e) {}

            try {
              document.querySelectorAll("*").forEach((el) => {
                if (!el || !el.style) return;
                if (el.getAttribute("role") === "progressbar" || el.className.toString().toLowerCase().includes("progress")) {
                  try { el.style.animationPlayState = "paused"; } catch (e) {}
                  try { el.style.transitionDuration = "999999s"; } catch (e) {}
                }
              });
            } catch (e) {}
          };

          pauseStory();
        JS
      rescue StandardError
        nil
      end

      def normalize_story_id_token(value)
        token = value.to_s.strip
        return "" if token.blank?

        token = token.split(/[?#]/).first.to_s
        token = token.split("/").first.to_s
        return "" if token.blank?
        return "" if token.casecmp("unknown").zero?
        return "" if token.casecmp("sig").zero?
        return "" if token.start_with?("sig:")

        digits = token.gsub(/\D/, "")
        digits.presence || ""
      rescue StandardError
        ""
      end

      def canonical_story_url(username:, story_id:, fallback_url:)
        uname = normalize_username(username)
        sid = normalize_story_id_token(story_id)
        return "#{INSTAGRAM_BASE_URL}/stories/#{uname}/#{sid}/" if uname.present? && sid.present?
        return "#{INSTAGRAM_BASE_URL}/stories/#{uname}/" if uname.present?

        fallback_url.to_s
      rescue StandardError
        fallback_url.to_s
      end

      def story_id_hint_from_media_url(url)
        value = url.to_s.strip
        return "" if value.blank?

        begin
          uri = URI.parse(value)
          query = Rack::Utils.parse_query(uri.query.to_s)
          raw_ig_cache = query["ig_cache_key"].to_s
          if raw_ig_cache.present?
            decoded = Base64.decode64(CGI.unescape(raw_ig_cache)).to_s
            if (m = decoded.match(/(\d{8,})/))
              return m[1].to_s
            end
          end
        rescue StandardError
          nil
        end

        if (m = value.match(%r{/stories/[A-Za-z0-9._]{1,30}/(\d{8,})}))
          return m[1].to_s
        end

        ""
      rescue StandardError
        ""
      end

      def current_story_reference(url)
        value = url.to_s
        return "" unless value.include?("/stories/")

        rest = value.split("/stories/").last.to_s
        username = rest.split("/").first.to_s
        story_id = rest.split("/")[1].to_s
        return "" if username.blank?

        "#{username}:#{story_id}"
      end

      def extract_username_from_profile_like_path(url)
        value = url.to_s
        return "" if value.blank?

        begin
          uri = URI.parse(value)
          path = uri.path.to_s
        rescue StandardError
          path = value
        end

        segment = path.split("/").reject(&:blank?).first.to_s
        return "" if segment.blank?
        return "" if segment.casecmp("stories").zero?
        return "" unless segment.match?(/\A[a-zA-Z0-9._]{1,30}\z/)

        segment
      end

      def ensure_story_same_or_reload!(driver:, expected_ref:, username:)
        return if expected_ref.to_s.blank?
        return if current_story_reference(driver.current_url.to_s) == expected_ref

        story_id = expected_ref.to_s.split(":")[1].to_s
        path = story_id.present? ? "/stories/#{username}/#{story_id}/" : "/stories/#{username}/"
        driver.navigate.to("#{INSTAGRAM_BASE_URL}#{path}")
        wait_for(driver, css: "body", timeout: 12)
        dismiss_common_overlays!(driver)
        capture_task_html(
          driver: driver,
          task_name: "auto_engage_story_reloaded",
          status: "ok",
          meta: { expected_ref: expected_ref, current_ref: current_story_reference(driver.current_url.to_s) }
        )
      end
    end
  end
end
