require "selenium-webdriver"
require "fileutils"
require "time"
require "net/http"
require "json"
require "cgi"
require "base64"
require "digest"
require "stringio"
require "set"

module Instagram
  class Client
    include StoryScraperService
    include FeedEngagementService
    include BrowserAutomation
    include DirectMessagingService
    include CommentPostingService
    include FollowGraphFetchingService
    include ProfileFetchingService
    include FeedFetchingService
    include SyncCollectionSupport
    include StoryApiSupport
    include CoreHelpers
    include TaskCaptureSupport
    include SessionRecoverySupport
    INSTAGRAM_BASE_URL = "https://www.instagram.com".freeze
    DEBUG_CAPTURE_DIR = Rails.root.join("log", "instagram_debug").freeze
    STORY_INTERACTION_RETRY_DAYS = 3
    PROFILE_FEED_PAGE_SIZE = 30
    PROFILE_FEED_MAX_PAGES = 120
    PROFILE_FEED_BROWSER_ITEM_CAP = 500

    def initialize(account:)
      @account = account
    end

    def manual_login!(timeout_seconds: 180)
      with_driver(headless: false) do |driver|
        driver.navigate.to("#{INSTAGRAM_BASE_URL}/accounts/login/")
        wait_for_manual_login!(driver: driver, timeout_seconds: timeout_seconds)

        persist_session_bundle!(driver)
        @account.login_state = "authenticated"
        @account.save!
      end
    end

    def validate_session!
      SessionValidationService.new(
        account: @account,
        with_driver: method(:with_driver),
        wait_for: method(:wait_for),
        logger: defined?(Rails) ? Rails.logger : nil
      ).call
    end


    def fetch_profile_analysis_dataset!(username:, posts_limit: nil, comments_limit: 8)
      ProfileAnalysisDatasetService.new(
        fetch_profile_details: method(:fetch_profile_details!),
        fetch_web_profile_info: method(:fetch_web_profile_info),
        fetch_profile_feed_items_for_analysis: method(:fetch_profile_feed_items_for_analysis),
        extract_post_for_analysis: method(:extract_post_for_analysis),
        enrich_missing_post_comments_via_browser: method(:enrich_missing_post_comments_via_browser!),
        normalize_username: method(:normalize_username)
      ).call(username: username, posts_limit: posts_limit, comments_limit: comments_limit)
    end

    def fetch_profile_story_dataset!(username:, stories_limit: 20)
      ProfileStoryDatasetService.new(
        fetch_profile_details: method(:fetch_profile_details!),
        fetch_web_profile_info: method(:fetch_web_profile_info),
        fetch_story_reel: method(:fetch_story_reel),
        extract_story_item: method(:extract_story_item),
        normalize_username: method(:normalize_username)
      ).call(username: username, stories_limit: stories_limit)
    end

    private

    def auto_engage_first_story!(driver:, story_hold_seconds:)
      result = { attempted: false, replied: false, replied_count: 0, username: nil, story_ref: nil, processed_stories: 0 }

      username = fetch_story_users_via_api.keys.first.to_s
      if username.blank?
        result[:reply_skipped] = true
        result[:reply_skip_reason] = "api_story_users_unavailable"
        return result
      end
      return result if username.blank?

      result[:attempted] = true
      result[:username] = username

      profile = find_story_network_profile(username: username)
      unless profile
        capture_task_html(
          driver: driver,
          task_name: "auto_engage_story_out_of_network_skipped",
          status: "ok",
          meta: { username: username, reason: "profile_not_in_network" }
        )
        result[:reply_skipped] = true
        result[:reply_skip_reason] = "profile_not_in_network"
        return result
      end

      story_items = fetch_story_items_via_api(username: username)
      if story_items.blank?
        result[:reply_skipped] = true
        result[:reply_skip_reason] = "no_story_items"
        return result
      end

      story_items.each do |story|
        story_id = story[:story_id].to_s
        next if story_id.blank?

        result[:processed_stories] += 1
        story_ref = "#{username}:#{story_id}"
        result[:story_ref] ||= story_ref

        if ActiveModel::Type::Boolean.new.cast(story[:api_should_skip])
          result[:reply_skipped] = true
          result[:reply_skip_reason] = story[:api_external_profile_reason].to_s.presence || "api_external_profile_indicator"
          next
        end

        can_reply = story[:can_reply]
        if can_reply == false
          result[:reply_skipped] = true
          result[:reply_skip_reason] = "api_can_reply_false"
          next
        end

        media_url = story[:media_url].to_s
        next if media_url.blank?

        download = download_media_with_metadata(url: media_url, user_agent: @account.user_agent)
        downloaded_at = Time.current
        downloaded_event = profile.record_event!(
          kind: "story_media_downloaded_via_feed",
          external_id: "story_media_downloaded_via_feed:#{story_ref}:#{downloaded_at.utc.iso8601(6)}",
          occurred_at: downloaded_at,
          metadata: {
            source: "selenium_story_viewer",
            media_source: "api_story_item",
            media_type: story[:media_type],
            username: username,
            story_id: story_id,
            story_ref: story_ref,
            download_link: media_url,
            media_size_bytes: download[:bytes].bytesize,
            content_type: download[:content_type],
            final_url: download[:final_url]
          }
        )
        downloaded_event.media.attach(
          io: StringIO.new(download[:bytes]),
          filename: download[:filename],
          content_type: download[:content_type]
        )
        InstagramProfileEvent.broadcast_story_archive_refresh!(account: @account)

        payload = build_auto_engagement_post_payload(
          profile: profile,
          shortcode: story_ref,
          caption: story[:caption],
          permalink: story[:permalink].to_s.presence || "#{INSTAGRAM_BASE_URL}/stories/#{username}/#{story_id}/",
          include_story_history: true
        )
        analysis = analyze_for_auto_engagement!(
          analyzable: downloaded_event,
          payload: payload,
          bytes: download[:bytes],
          content_type: download[:content_type],
          source_url: media_url
        )
        suggestions = generate_comment_suggestions_from_analysis!(
          profile: profile,
          payload: payload,
          analysis: analysis
        )
        comment_text = suggestions.first.to_s.strip
        next if comment_text.blank?

        comment_result = comment_on_story_via_api!(story_id: story_id, story_username: username, comment_text: comment_text)
        if !comment_result[:posted]
          driver.navigate.to("#{INSTAGRAM_BASE_URL}/stories/#{username}/#{story_id}/")
          wait_for(driver, css: "body", timeout: 12)
          dismiss_common_overlays!(driver)
          freeze_story_progress!(driver)
          comment_result = comment_on_story_via_ui!(driver: driver, comment_text: comment_text)
        end
        posted = comment_result[:posted]
        sleep(story_hold_seconds.to_i) if posted

        if posted
          result[:replied] = true
          result[:replied_count] = result[:replied_count].to_i + 1
          profile.record_event!(
            kind: "story_comment_posted_via_feed",
            external_id: "story_comment_posted_via_feed:#{story_ref}:#{Time.current.utc.iso8601(6)}",
            occurred_at: Time.current,
            metadata: {
              source: "selenium_story_viewer",
              username: username,
              story_id: story_id,
              story_ref: story_ref,
              comment_text: comment_text,
              submission_method: comment_result[:method],
              analysis: analysis
            }
          )
          attach_reply_comment_to_downloaded_event!(downloaded_event: downloaded_event, comment_text: comment_text)
        end
      rescue StandardError
        next
      end

      result
    rescue StandardError => e
      capture_task_html(
        driver: driver,
        task_name: "auto_engage_story_failed",
        status: "error",
        meta: { error_class: e.class.name, error_message: e.message }
      )
      result
    end

    def auto_engage_feed_post!(driver:, item:)
      shortcode = item[:shortcode].to_s
      username = normalize_username(item[:author_username].to_s)
      profile = find_or_create_profile_for_auto_engagement!(username: username)

      capture_task_html(
        driver: driver,
        task_name: "auto_engage_post_selected",
        status: "ok",
        meta: { shortcode: shortcode, username: username, media_url: item[:media_url] }
      )

      download = download_media_with_metadata(url: item[:media_url], user_agent: @account.user_agent)
      downloaded_at = Time.current
      downloaded_event = profile.record_event!(
        kind: "feed_post_image_downloaded",
        external_id: "feed_post_image_downloaded:#{shortcode}:#{downloaded_at.utc.iso8601(6)}",
        occurred_at: downloaded_at,
        metadata: {
          source: "selenium_home_feed",
          shortcode: shortcode,
          download_link: item[:media_url],
          original_image_size_bytes: download[:bytes].bytesize,
          original_image_width: item.dig(:metadata, :natural_width),
          original_image_height: item.dig(:metadata, :natural_height),
          content_type: download[:content_type],
          final_url: download[:final_url]
        }
      )
      downloaded_event.media.attach(
        io: StringIO.new(download[:bytes]),
        filename: download[:filename],
        content_type: download[:content_type]
      )

      payload = build_auto_engagement_post_payload(
        profile: profile,
        shortcode: shortcode,
        caption: item[:caption],
        permalink: "#{INSTAGRAM_BASE_URL}/p/#{shortcode}/",
        include_story_history: false
      )
      analysis = analyze_for_auto_engagement!(
        analyzable: downloaded_event,
        payload: payload,
        bytes: download[:bytes],
        content_type: download[:content_type],
        source_url: item[:media_url]
      )
      suggestions = generate_comment_suggestions_from_analysis!(
        profile: profile,
        payload: payload,
        analysis: analysis
      )

      comment_text = suggestions.first.to_s.strip
      posted = comment_text.present? && comment_on_post_via_ui!(driver: driver, shortcode: shortcode, comment_text: comment_text)

      profile.record_event!(
        kind: "feed_post_comment_posted",
        external_id: "feed_post_comment_posted:#{shortcode}:#{Time.current.utc.iso8601(6)}",
        occurred_at: Time.current,
        metadata: {
          source: "selenium_home_feed",
          shortcode: shortcode,
          username: username,
          posted: posted,
          posted_comment: comment_text,
          generated_suggestions: suggestions.first(8),
          analysis: analysis
        }
      )

      {
        shortcode: shortcode,
        username: username,
        comment_posted: posted,
        posted_comment: comment_text
      }
    end

    def find_or_create_profile_for_auto_engagement!(username:)
      normalized = normalize_username(username)
      raise "Feed item username is missing" if normalized.blank?

      @account.instagram_profiles.find_or_create_by!(username: normalized) do |profile|
        profile.display_name = normalized
        profile.can_message = nil
      end
    end

    def find_story_network_profile(username:)
      normalized = normalize_username(username)
      return nil if normalized.blank?

      @account.instagram_profiles
        .where(username: normalized)
        .where("following = ? OR follows_you = ?", true, true)
        .first
    rescue StandardError
      nil
    end

    def find_profile_for_interaction(username:)
      normalized = normalize_username(username)
      return nil if normalized.blank?

      @account.instagram_profiles.where(username: normalized).first
    rescue StandardError
      nil
    end

    def profile_auto_reply_enabled?(profile)
      return profile.auto_reply_enabled? if profile.respond_to?(:auto_reply_enabled?)

      profile.profile_tags.where(name: [ "automatic_reply", "automatic reply", "auto_reply", "auto reply" ]).exists?
    end

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


    def download_media_with_metadata(url:, user_agent:, redirect_limit: 3)
      uri = URI.parse(url.to_s)
      raise "Invalid media URL" unless uri.is_a?(URI::HTTP) || uri.is_a?(URI::HTTPS)

      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = (uri.scheme == "https")
      http.open_timeout = 10
      http.read_timeout = 30

      req = Net::HTTP::Get.new(uri.request_uri)
      req["User-Agent"] = user_agent.presence || "Mozilla/5.0"
      req["Accept"] = "*/*"
      req["Referer"] = INSTAGRAM_BASE_URL
      res = http.request(req)

      if res.is_a?(Net::HTTPRedirection) && res["location"].present? && redirect_limit.to_i.positive?
        return download_media_with_metadata(url: res["location"], user_agent: user_agent, redirect_limit: redirect_limit.to_i - 1)
      end

      raise "Media download failed: HTTP #{res.code}" unless res.is_a?(Net::HTTPSuccess)

      body = res.body.to_s
      raise "Downloaded media is empty" if body.blank?

      content_type = res["content-type"].to_s.split(";").first.presence || "image/jpeg"
      digest = Digest::SHA256.hexdigest("#{uri.path}-#{body.bytesize}")[0, 12]
      {
        bytes: body,
        content_type: content_type,
        filename: "feed_media_#{digest}.#{extension_for_content_type(content_type: content_type)}",
        final_url: uri.to_s
      }
    end

    def extension_for_content_type(content_type:)
      return "jpg" if content_type.include?("jpeg")
      return "png" if content_type.include?("png")
      return "webp" if content_type.include?("webp")
      return "gif" if content_type.include?("gif")
      return "mp4" if content_type.include?("mp4")
      return "mov" if content_type.include?("quicktime")

      "bin"
    end

    def build_auto_engagement_post_payload(profile:, shortcode:, caption:, permalink:, include_story_history: false)
      history = include_story_history ? recent_story_and_post_history(profile: profile) : {}
      history_narrative = profile.history_narrative_text(max_chunks: 3)
      history_chunks = profile.history_narrative_chunks(max_chunks: 6)

      {
        post: {
          shortcode: shortcode,
          caption: caption.to_s.presence,
          taken_at: nil,
          permalink: permalink,
          likes_count: nil,
          comments_count: nil,
          comments: []
        },
        author_profile: {
          username: profile.username,
          display_name: profile.display_name,
          bio: profile.bio,
          can_message: profile.can_message,
          tags: profile.profile_tags.pluck(:name).sort
        },
        rules: {
          require_manual_review: false,
          style: "gen_z_light",
          diversity_requirement: "Avoid repeating prior story comments; generate novel phrasing.",
          engagement_history: history,
          historical_narrative_text: history_narrative,
          historical_narrative_chunks: history_chunks
        }
      }
    end

    def analyze_for_auto_engagement!(analyzable:, payload:, bytes:, content_type:, source_url:)
      media = build_auto_engagement_media_payload(bytes: bytes, content_type: content_type, source_url: source_url)
      run = Ai::Runner.new(account: @account).analyze!(
        purpose: "post",
        analyzable: analyzable,
        payload: payload,
        media: media,
        media_fingerprint: Digest::SHA256.hexdigest(bytes)
      )

      run.dig(:result, :analysis).is_a?(Hash) ? run.dig(:result, :analysis) : {}
    rescue StandardError
      {}
    end

    def build_auto_engagement_media_payload(bytes:, content_type:, source_url:)
      payload = {
        type: "image",
        content_type: content_type,
        bytes: bytes,
        url: source_url.to_s
      }
      if bytes.bytesize <= 2 * 1024 * 1024
        payload[:image_data_url] = "data:#{content_type};base64,#{Base64.strict_encode64(bytes)}"
      end
      payload
    end

    def generate_comment_suggestions_from_analysis!(profile:, payload:, analysis:)
      preparation = ensure_profile_comment_generation_readiness(profile: profile)
      unless ActiveModel::Type::Boolean.new.cast(preparation[:ready_for_comment_generation] || preparation["ready_for_comment_generation"])
        log_automation_event(
          task_name: "comment_generation_blocked_profile_preparation",
          severity: "warn",
          details: {
            profile_id: profile&.id,
            username: profile&.username,
            reason_code: preparation[:reason_code] || preparation["reason_code"],
            reason: preparation[:reason] || preparation["reason"]
          }
        )
        return []
      end

      suggestions = Array(analysis["comment_suggestions"]).map(&:to_s).map(&:strip).reject(&:blank?).uniq
      suggestions = ensure_story_comment_diversity(profile: profile, suggestions: suggestions)
      return suggestions if suggestions.present?

      generated = generate_google_engagement_comments!(
        payload: payload,
        image_description: analysis["image_description"],
        topics: Array(analysis["topics"]),
        author_type: analysis["author_type"].to_s
      )
      ensure_story_comment_diversity(profile: profile, suggestions: generated)
    end

    def ensure_profile_comment_generation_readiness(profile:)
      return { ready_for_comment_generation: false, reason_code: "profile_missing", reason: "Profile missing." } unless profile

      @profile_comment_preparation_cache ||= {}
      cached = @profile_comment_preparation_cache[profile.id]
      return cached if cached.is_a?(Hash)

      summary = Ai::ProfileCommentPreparationService.new(
        account: @account,
        profile: profile,
        posts_limit: 10,
        comments_limit: 12
      ).prepare!
      @profile_comment_preparation_cache[profile.id] = summary.is_a?(Hash) ? summary : {}
    rescue StandardError => e
      {
        ready_for_comment_generation: false,
        reason_code: "profile_preparation_error",
        reason: e.message.to_s,
        error_class: e.class.name
      }
    end

    def recent_story_and_post_history(profile:)
      story_items = profile.instagram_profile_events
        .where(kind: [ "story_analyzed", "story_reply_sent", "story_comment_posted_via_feed" ])
        .order(detected_at: :desc, id: :desc)
        .limit(12)
        .map do |event|
          m = event.metadata.is_a?(Hash) ? event.metadata : {}
          {
            kind: event.kind,
            story_id: m["story_id"].to_s.presence,
            image_description: m["ai_image_description"].to_s.presence,
            sent_comment: m["ai_reply_text"].to_s.presence || m["comment_text"].to_s.presence
          }.compact
        end

      post_items = profile.instagram_profile_posts.recent_first.limit(8).map do |p|
        a = p.analysis.is_a?(Hash) ? p.analysis : {}
        {
          shortcode: p.shortcode,
          image_description: a["image_description"].to_s.presence,
          topics: Array(a["topics"]).first(5)
        }.compact
      end

      {
        prior_story_items: story_items,
        prior_post_items: post_items
      }
    end

    def ensure_story_comment_diversity(profile:, suggestions:)
      candidates = Array(suggestions).map(&:to_s).map(&:strip).reject(&:blank?).uniq
      return [] if candidates.empty?

      history = profile.instagram_profile_events
        .where(kind: [ "story_reply_sent", "story_comment_posted_via_feed" ])
        .order(detected_at: :desc, id: :desc)
        .limit(40)
        .map do |event|
          m = event.metadata.is_a?(Hash) ? event.metadata : {}
          m["ai_reply_text"].to_s.presence || m["comment_text"].to_s.presence
        end
        .compact

      return candidates if history.empty?

      ranked = candidates.sort_by do |candidate|
        history.map { |past| text_similarity_score(candidate, past) }.max.to_f
      end

      unique = ranked.select { |candidate| history.all? { |past| text_similarity_score(candidate, past) < 0.72 } }
      unique.present? ? unique : ranked
    end

    def story_already_replied?(profile:, story_id:, story_ref:, story_url:, media_url:)
      sid = story_id.to_s.strip
      sref = story_ref.to_s.strip
      surl = normalize_story_permalink(story_url)
      mkey = normalize_story_media_key(media_url)

      profile.instagram_profile_events
        .where(kind: "story_reply_sent")
        .order(detected_at: :desc, id: :desc)
        .limit(250)
        .each do |event|
          metadata = event.metadata.is_a?(Hash) ? event.metadata : {}
          event_sid = metadata["story_id"].to_s.strip
          event_sref = metadata["story_ref"].to_s.strip
          event_surl = normalize_story_permalink(metadata["story_url"])
          event_mkey = normalize_story_media_key(metadata["media_url"])

          if sid.present? && (event_sid == sid || event.external_id.to_s == "story_reply_sent:#{sid}")
            return { found: true, matched_by: "story_id", matched_external_id: event.external_id.to_s }
          end
          if sref.present? && event_sref.present? && event_sref == sref
            return { found: true, matched_by: "story_ref", matched_external_id: event.external_id.to_s }
          end
          if surl.present? && event_surl.present? && event_surl == surl
            return { found: true, matched_by: "story_url", matched_external_id: event.external_id.to_s }
          end
          if mkey.present? && event_mkey.present? && event_mkey == mkey
            return { found: true, matched_by: "media_url", matched_external_id: event.external_id.to_s }
          end
        end

      { found: false, matched_by: nil, matched_external_id: nil }
    end

    def normalize_story_permalink(url)
      value = url.to_s.strip
      return "" if value.blank?

      begin
        uri = URI.parse(value)
        path = uri.path.to_s
      rescue StandardError
        path = value
      end

      return "" unless path.include?("/stories/")
      path.sub(%r{/\z}, "")
    end

    def normalize_story_media_key(url)
      value = url.to_s.strip
      return "" if value.blank?

      begin
        uri = URI.parse(value)
        host = uri.host.to_s
        path = uri.path.to_s
        return "" if host.blank? || path.blank?
        "#{host}#{path}"
      rescue StandardError
        value
      end
    end

    def text_similarity_score(a, b)
      left = a.to_s.downcase.scan(/[a-z0-9]+/).uniq
      right = b.to_s.downcase.scan(/[a-z0-9]+/).uniq
      return 0.0 if left.empty? || right.empty?

      (left & right).length.to_f / [ left.length, right.length ].max.to_f
    end

    def comment_on_post_via_ui!(driver:, shortcode:, comment_text:)
      driver.navigate.to("#{INSTAGRAM_BASE_URL}/p/#{shortcode}/")
      wait_for(driver, css: "body", timeout: 12)
      dismiss_common_overlays!(driver)
      capture_task_html(driver: driver, task_name: "auto_engage_post_opened", status: "ok", meta: { shortcode: shortcode })

      field = wait_for_comment_textbox(driver: driver)
      return false unless field

      focus_and_type(driver: driver, field: field, text: comment_text)
      posted = click_comment_post_button(driver: driver)
      sleep(0.6)
      capture_task_html(
        driver: driver,
        task_name: "auto_engage_post_comment_submit",
        status: posted ? "ok" : "error",
        meta: { shortcode: shortcode, posted: posted }
      )
      posted
    rescue StandardError
      false
    end

    def comment_on_story_via_ui!(driver:, comment_text:)
      field = wait_for_comment_textbox(driver: driver, timeout: 12)
      if !field
        availability = detect_story_reply_availability(driver)
        return {
          posted: false,
          reason: availability[:reason],
          marker_text: availability[:marker_text]
        }
      end

      capture_task_html(driver: driver, task_name: "auto_engage_story_reply_box_ready", status: "ok")
      focus_and_type(driver: driver, field: field, text: comment_text)
      posted = click_comment_post_button(driver: driver)
      if posted
        return { posted: true, reason: "post_button_clicked" }
      end

      enter_posted = send_enter_comment(driver: driver, field: field)
      return { posted: true, reason: "submitted_with_enter" } if enter_posted

      { posted: false, reason: "submit_controls_not_found" }
    rescue StandardError => e
      { posted: false, reason: "exception:#{e.class.name}" }
    end

    # API-first story reply path discovered from captured network traces:
    # 1) POST /api/v1/direct_v2/create_group_thread/ with recipient_users=["<reel_user_id>"]
    # 2) POST /api/v1/direct_v2/threads/broadcast/reel_share/ with media_id="<story_id>_<reel_user_id>", reel_id, thread_id, text
    def comment_on_story_via_api!(story_id:, story_username:, comment_text:)
      text = comment_text.to_s.strip
      return { posted: false, method: "api", reason: "blank_comment_text" } if text.blank?

      sid = story_id.to_s.strip.gsub(/[^0-9]/, "")
      return { posted: false, method: "api", reason: "missing_story_id" } if sid.blank?

      username = normalize_username(story_username)
      return { posted: false, method: "api", reason: "missing_story_username" } if username.blank?

      user_id = story_user_id_for(username: username)
      return { posted: false, method: "api", reason: "missing_story_user_id" } if user_id.blank?

      thread_id = direct_thread_id_for_user(user_id: user_id)
      return { posted: false, method: "api", reason: "missing_thread_id" } if thread_id.blank?

      payload = {
        action: "send_item",
        client_context: story_api_client_context,
        media_id: "#{sid}_#{user_id}",
        reel_id: user_id,
        text: text,
        thread_id: thread_id
      }

      body = ig_api_post_form_json(
        path: "/api/v1/direct_v2/threads/broadcast/reel_share/",
        referer: "#{INSTAGRAM_BASE_URL}/stories/#{username}/#{sid}/",
        form: payload
      )
      return { posted: false, method: "api", reason: "empty_api_response" } unless body.is_a?(Hash)

      status = body["status"].to_s
      if status == "ok"
        return {
          posted: true,
          method: "api",
          reason: "reel_share_sent",
          api_status: status,
          api_thread_id: body.dig("payload", "thread_id").to_s.presence,
          api_item_id: body.dig("payload", "item_id").to_s.presence
        }
      end

      {
        posted: false,
        method: "api",
        reason: body["message"].to_s.presence || body.dig("payload", "message").to_s.presence || body["error_type"].to_s.presence || "api_status_#{status.presence || 'unknown'}",
        api_status: status.presence || "unknown",
        api_http_status: body["_http_status"],
        api_error_code: body.dig("payload", "error_code").to_s.presence || body["error_code"].to_s.presence
      }
    rescue StandardError => e
      { posted: false, method: "api", reason: "api_exception:#{e.class.name}" }
    end

    def story_user_id_for(username:)
      @story_user_id_cache ||= {}
      uname = normalize_username(username)
      return "" if uname.blank?
      cached = @story_user_id_cache[uname].to_s
      return cached if cached.present?

      web_info = fetch_web_profile_info(uname)
      user = web_info.is_a?(Hash) ? web_info.dig("data", "user") : nil
      uid = user.is_a?(Hash) ? user["id"].to_s.strip : ""
      @story_user_id_cache[uname] = uid if uid.present?
      uid
    rescue StandardError
      ""
    end

    def direct_thread_id_for_user(user_id:)
      create_direct_thread_for_user(user_id: user_id, use_cache: true)[:thread_id].to_s
    rescue StandardError
      ""
    end

    def create_direct_thread_for_user(user_id:, use_cache: true)
      @story_reply_thread_cache ||= {}
      uid = user_id.to_s.strip
      return { thread_id: "", reason: "blank_user_id" } if uid.blank?

      if use_cache
        cached = @story_reply_thread_cache[uid].to_s
        return { thread_id: cached, reason: "cache_hit" } if cached.present?
      end

      body = ig_api_post_form_json(
        path: "/api/v1/direct_v2/create_group_thread/",
        referer: "#{INSTAGRAM_BASE_URL}/direct/new/",
        form: { recipient_users: [ uid ].to_json }
      )
      return { thread_id: "", reason: "empty_api_response" } unless body.is_a?(Hash)

      thread_id =
        body["thread_id"].to_s.presence ||
        body.dig("thread", "thread_id").to_s.presence ||
        body.dig("thread", "id").to_s.presence

      if thread_id.present?
        @story_reply_thread_cache[uid] = thread_id
        return {
          thread_id: thread_id,
          reason: "thread_created",
          api_status: body["status"].to_s.presence || "ok",
          api_http_status: body["_http_status"]
        }
      end

      {
        thread_id: "",
        reason: body["message"].to_s.presence || body["error_type"].to_s.presence || "missing_thread_id",
        api_status: body["status"].to_s.presence || "unknown",
        api_http_status: body["_http_status"],
        api_error_code: body["error_code"].to_s.presence || body.dig("payload", "error_code").to_s.presence
      }
    rescue StandardError => e
      { thread_id: "", reason: "api_exception:#{e.class.name}" }
    end

    def story_api_client_context
      "#{(Time.current.to_f * 1000).to_i}#{rand(1_000_000..9_999_999)}"
    end

    def ig_api_post_form_json(path:, referer:, form:)
      uri = URI.parse(path.to_s.start_with?("http") ? path.to_s : "#{INSTAGRAM_BASE_URL}#{path}")

      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = (uri.scheme == "https")
      http.open_timeout = 10
      http.read_timeout = 20

      req = Net::HTTP::Post.new(uri.request_uri)
      req["User-Agent"] = @account.user_agent.presence || "Mozilla/5.0"
      req["Accept"] = "application/json, text/plain, */*"
      req["Content-Type"] = "application/x-www-form-urlencoded; charset=UTF-8"
      req["X-Requested-With"] = "XMLHttpRequest"
      req["X-IG-App-ID"] = (@account.auth_snapshot.dig("ig_app_id").presence || "936619743392459")
      req["Referer"] = referer.to_s

      csrf = @account.cookies.find { |c| c["name"].to_s == "csrftoken" }&.dig("value").to_s
      req["X-CSRFToken"] = csrf if csrf.present?
      req["Cookie"] = cookie_header_for(@account.cookies)
      req.set_form_data(form.transform_values { |v| v.to_s })

      res = http.request(req)
      return nil unless res["content-type"].to_s.include?("json")

      body = JSON.parse(res.body.to_s)
      body["_http_status"] = res.code.to_i
      body
    rescue StandardError
      nil
    end

    def detect_story_reply_availability(driver)
      payload = driver.execute_script(<<~JS)
        const out = { reason: "reply_box_not_found", marker_text: "" };
        const norm = (value) => (value || "").toString().replace(/\\s+/g, " ").trim().toLowerCase();
        const texts = Array.from(document.querySelectorAll("body *"))
          .filter((el) => {
            if (!el) return false;
            if (el.children && el.children.length > 0) return false;
            const r = el.getBoundingClientRect();
            return r.width > 3 && r.height > 3;
          })
          .map((el) => norm(el.innerText || el.textContent))
          .filter((t) => t.length > 0 && t.length < 140);

        const joined = texts.join(" | ");
        const matchAny = (patterns) => patterns.find((p) => joined.includes(p));

        const repliesNotAllowed = matchAny([
          "replies aren't available",
          "replies are turned off",
          "replies are off",
          "can't reply to this story",
          "you can't reply to this story",
          "reply unavailable"
        ]);
        if (repliesNotAllowed) {
          out.reason = "replies_not_allowed";
          out.marker_text = repliesNotAllowed;
          return out;
        }

        const unavailable = matchAny([
          "story unavailable",
          "this story is unavailable",
          "content unavailable",
          "not available right now",
          "unavailable"
        ]);
        if (unavailable) {
          out.reason = "reply_unavailable";
          out.marker_text = unavailable;
          return out;
        }

        return out;
      JS

      return { reason: "reply_box_not_found", marker_text: "" } unless payload.is_a?(Hash)

      {
        reason: payload["reason"].to_s.presence || "reply_box_not_found",
        marker_text: payload["marker_text"].to_s
      }
    rescue StandardError
      { reason: "reply_box_not_found", marker_text: "" }
    end

    def story_reply_skip_status_for(comment_result = nil, reason: nil)
      reason = reason.to_s if reason.present?
      reason ||= comment_result.to_h[:reason].to_s
      case reason
      when "api_can_reply_false"
        { reason_code: "api_can_reply_false", status: "Replies not allowed (API)" }
      when "reply_box_not_found"
        { reason_code: "reply_box_not_found", status: "Reply box not found" }
      when "replies_not_allowed"
        { reason_code: "replies_not_allowed", status: "Replies not allowed" }
      when "reply_unavailable"
        { reason_code: "reply_unavailable", status: "Unavailable" }
      when "reply_precheck_error"
        { reason_code: "reply_precheck_error", status: "Unavailable" }
      else
        { reason_code: "comment_submit_failed", status: "Unavailable" }
      end
    end

    def story_reply_capability_from_api(username:, story_id:)
      item = resolve_story_item_via_api(username: username, story_id: story_id)
      return { known: false, reply_possible: nil, reason_code: "api_story_not_found", status: "Unknown" } unless item.is_a?(Hash)

      can_reply = item[:can_reply]
      return { known: false, reply_possible: nil, reason_code: "api_can_reply_missing", status: "Unknown" } if can_reply.nil?

      if can_reply
        { known: true, reply_possible: true, reason_code: nil, status: "Reply available (API)" }
      else
        { known: true, reply_possible: false, reason_code: "api_can_reply_false", status: "Replies not allowed (API)" }
      end
    rescue StandardError => e
      { known: false, reply_possible: nil, reason_code: "api_capability_error", status: "Unknown" }
    end

    def story_external_profile_link_context_from_api(username:, story_id:, cache: nil)
      item = resolve_story_item_via_api(username: username, story_id: story_id, cache: cache)
      return { known: false, has_external_profile_link: false, reason_code: "api_story_not_found", linked_username: "", linked_profile_url: "", marker_text: "", linked_targets: [] } unless item.is_a?(Hash)

      has_external = ActiveModel::Type::Boolean.new.cast(item[:api_has_external_profile_indicator])
      return { known: true, has_external_profile_link: false, reason_code: nil, linked_username: "", linked_profile_url: "", marker_text: "", linked_targets: [] } unless has_external

      reason = item[:api_external_profile_reason].to_s.presence || "api_external_profile_indicator"
      targets = Array(item[:api_external_profile_targets]).map(&:to_s).map(&:strip).reject(&:blank?).uniq
      {
        known: true,
        has_external_profile_link: true,
        reason_code: reason,
        linked_username: "",
        linked_profile_url: "",
        marker_text: reason,
        linked_targets: targets
      }
    rescue StandardError
      { known: false, has_external_profile_link: false, reason_code: "api_external_context_error", linked_username: "", linked_profile_url: "", marker_text: "", linked_targets: [] }
    end

    def check_story_reply_capability(driver:)
      field = wait_for_comment_textbox(driver: driver, timeout: 2)
      return { reply_possible: true, reason_code: nil, status: "Reply available", marker_text: "", submission_reason: "reply_box_found" } if field

      availability = detect_story_reply_availability(driver)
      status = story_reply_skip_status_for(reason: availability[:reason])
      {
        reply_possible: false,
        reason_code: status[:reason_code],
        status: status[:status],
        marker_text: availability[:marker_text].to_s,
        submission_reason: availability[:reason].to_s
      }
    rescue StandardError => e
      {
        reply_possible: false,
        reason_code: "reply_precheck_error",
        status: "Unavailable",
        marker_text: "",
        submission_reason: "exception:#{e.class.name}"
      }
    end

    def react_to_story_if_available!(driver:)
      payload = driver.execute_script(<<~JS)
        const out = { reacted: false, reason: "reaction_controls_not_found", marker_text: "" };
        const norm = (value) => (value || "").toString().replace(/\\s+/g, " ").trim().toLowerCase();
        const isVisible = (el) => {
          if (!el) return false;
          const s = window.getComputedStyle(el);
          if (!s || s.display === "none" || s.visibility === "hidden" || s.opacity === "0") return false;
          const r = el.getBoundingClientRect();
          if (r.width < 4 || r.height < 4) return false;
          return r.bottom > 0 && r.top < window.innerHeight;
        };

        const candidates = Array.from(document.querySelectorAll("button, [role='button']"))
          .filter((el) => {
            if (!isVisible(el)) return false;
            const r = el.getBoundingClientRect();
            return r.top >= Math.max(0, window.innerHeight * 0.45);
          });

        const scoreFor = (el) => {
          const text = norm(el.innerText || el.textContent);
          const aria = norm(el.getAttribute && el.getAttribute("aria-label"));
          const title = norm(el.getAttribute && el.getAttribute("title"));
          const all = `${text} | ${aria} | ${title}`;
          if (all.includes("quick reaction")) return 100;
          if (all.includes("reaction")) return 95;
          if (all.includes("react")) return 90;
          if (all.includes("like")) return 75;
          if (all.includes("heart")) return 70;
          if (/[❤️❤🔥😍😂👏😢😮]/.test(text)) return 60;
          return 0;
        };

        const sorted = candidates
          .map((el) => ({ el, score: scoreFor(el) }))
          .filter((entry) => entry.score > 0)
          .sort((a, b) => b.score - a.score);

        const chosen = sorted[0];
        if (!chosen || !chosen.el) return out;

        const marker = norm(chosen.el.innerText || chosen.el.textContent) || norm(chosen.el.getAttribute && chosen.el.getAttribute("aria-label")) || "reaction_button";
        try {
          chosen.el.click();
          out.reacted = true;
          out.reason = "reaction_button_clicked";
          out.marker_text = marker;
          return out;
        } catch (e) {
          out.reason = "reaction_click_failed";
          out.marker_text = marker;
          return out;
        }
      JS

      return { reacted: false, reason: "reaction_detection_error", marker_text: "" } unless payload.is_a?(Hash)

      {
        reacted: ActiveModel::Type::Boolean.new.cast(payload["reacted"]),
        reason: payload["reason"].to_s.presence || "reaction_controls_not_found",
        marker_text: payload["marker_text"].to_s
      }
    rescue StandardError => e
      { reacted: false, reason: "reaction_exception:#{e.class.name}", marker_text: "" }
    end

    def dm_interaction_retry_pending?(profile)
      return false unless profile
      return false unless profile.dm_interaction_state.to_s == "unavailable"

      retry_after = profile.dm_interaction_retry_after_at
      retry_after.present? && retry_after > Time.current
    end



    def profile_interaction_retry_pending?(profile)
      return false unless profile
      return false unless profile.story_interaction_state.to_s == "unavailable"

      retry_after = profile.story_interaction_retry_after_at
      retry_after.present? && retry_after > Time.current
    end

    def mark_profile_interaction_state!(profile:, state:, reason:, reaction_available:, retry_after_at: nil)
      return unless profile

      profile.update!(
        story_interaction_state: state.to_s.presence,
        story_interaction_reason: reason.to_s.presence,
        story_interaction_checked_at: Time.current,
        story_interaction_retry_after_at: retry_after_at,
        story_reaction_available: reaction_available.nil? ? profile.story_reaction_available : ActiveModel::Type::Boolean.new.cast(reaction_available)
      )
    rescue StandardError
      nil
    end

    def attach_reply_comment_to_downloaded_event!(downloaded_event:, comment_text:)
      return if downloaded_event.blank? || comment_text.blank?

      meta = downloaded_event.metadata.is_a?(Hash) ? downloaded_event.metadata.deep_dup : {}
      meta["reply_comment"] = comment_text.to_s
      downloaded_event.update!(metadata: meta)
    end

    def wait_for_comment_textbox(driver:, timeout: 10)
      Selenium::WebDriver::Wait.new(timeout: timeout).until do
        el =
          driver.find_elements(css: "textarea[aria-label*='comment'], textarea[aria-label*='Comment'], textarea[placeholder*='comment'], textarea[placeholder*='Comment'], textarea[placeholder*='reply'], textarea[placeholder*='Reply']").find { |x| x.displayed? rescue false } ||
          driver.find_elements(css: "div[role='textbox'][contenteditable='true']").find { |x| x.displayed? rescue false }
        break el if el
      end
    rescue Selenium::WebDriver::Error::TimeoutError
      nil
    end

    def focus_and_type(driver:, field:, text:)
      begin
        driver.execute_script("arguments[0].scrollIntoView({block:'center'});", field)
      rescue StandardError
        nil
      end

      begin
        field.click
      rescue StandardError
        nil
      end

      if field.tag_name.to_s.downcase == "div"
        driver.execute_script("arguments[0].focus();", field)
        field.send_keys(text.to_s)
      else
        field.send_keys([:control, "a"])
        field.send_keys(:backspace)
        field.send_keys(text.to_s)
      end
    end

    def click_comment_post_button(driver:)
      button =
        driver.find_elements(xpath: "//*[self::button or (self::div and @role='button')][normalize-space()='Post']").find { |el| element_enabled?(el) } ||
        driver.find_elements(xpath: "//*[self::button or (self::div and @role='button')][normalize-space()='Reply']").find { |el| element_enabled?(el) } ||
        driver.find_elements(xpath: "//*[self::button or (self::div and @role='button')][contains(translate(normalize-space(.), 'ABCDEFGHIJKLMNOPQRSTUVWXYZ', 'abcdefghijklmnopqrstuvwxyz'), 'post')]").find { |el| element_enabled?(el) } ||
        driver.find_elements(xpath: "//*[self::button or (self::div and @role='button')][contains(translate(normalize-space(.), 'ABCDEFGHIJKLMNOPQRSTUVWXYZ', 'abcdefghijklmnopqrstuvwxyz'), 'reply')]").find { |el| element_enabled?(el) }
      return false unless button

      begin
        driver.action.move_to(button).click.perform
      rescue StandardError
        js_click(driver, button)
      end
      true
    rescue StandardError
      false
    end

    def send_enter_comment(driver:, field:)
      begin
        driver.action.click(field).send_keys(:enter).perform
        true
      rescue StandardError
        false
      end
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

    def evaluate_story_image_quality(download:, media:)
      bytes = download.is_a?(Hash) ? download[:bytes].to_s.b : "".b
      content_type = download.is_a?(Hash) ? download[:content_type].to_s : ""
      width = media[:width].to_i
      height = media[:height].to_i

      return { skip: true, reason: "empty_download", entropy: nil } if bytes.blank?
      return { skip: true, reason: "too_small_bytes", entropy: nil } if bytes.bytesize < 1500
      return { skip: true, reason: "tiny_dimensions", entropy: nil } if width.positive? && height.positive? && (width < 120 || height < 120)

      entropy = bytes_entropy(bytes)

      # Heuristic: placeholder/blank assets are often very small and very low entropy.
      if content_type.start_with?("image/") && bytes.bytesize < 45_000 && entropy < 4.2
        return { skip: true, reason: "low_entropy_small_image", entropy: entropy }
      end

      { skip: false, reason: nil, entropy: entropy }
    rescue StandardError
      { skip: false, reason: nil, entropy: nil }
    end

    def bytes_entropy(bytes)
      data = bytes.to_s.b
      return 0.0 if data.empty?

      counts = Array.new(256, 0)
      data.each_byte { |b| counts[b] += 1 }

      len = data.bytesize.to_f
      entropy = 0.0
      counts.each do |count|
        next if count.zero?

        p = count / len
        entropy -= p * Math.log2(p)
      end
      entropy.round(4)
    end

    def detect_story_ad_context(driver:, media: nil)
      payload = driver.execute_script(<<~JS)
        const out = { ad_detected: false, reason: "", marker_text: "" };
        const explicitMarkers = [
          "sponsored",
          "sponsored post",
          "sponsored content",
          "promoted",
          "paid partnership",
          "advertisement"
        ];
        const norm = (value) => (value || "").toString().replace(/\\s+/g, " ").trim().toLowerCase();
        const isVisible = (el) => {
          if (!el) return false;
          const s = window.getComputedStyle(el);
          if (!s || s.display === "none" || s.visibility === "hidden" || s.opacity === "0") return false;
          const r = el.getBoundingClientRect();
          if (r.width < 4 || r.height < 4) return false;
          return r.bottom > 0 && r.top < window.innerHeight;
        };
        const inStoryHeaderZone = (el) => {
          const r = el.getBoundingClientRect();
          return r.top >= 0 && r.top <= Math.max(240, window.innerHeight * 0.38);
        };
        const matchesExplicitMarker = (text) => {
          if (!text) return "";
          for (const m of explicitMarkers) {
            if (text === m) return m;
            if (text.startsWith(`${m} `)) return m;
            if (text.endsWith(` ${m}`)) return m;
            if (text.includes(` ${m} `)) return m;
          }
          return "";
        };
        const markerRegex = /\b(sponsored|promoted|paid partnership|advertisement)\b/;

        const path = (window.location && window.location.pathname || "").toLowerCase();
        if (!path.includes("/stories/")) return out;

        // Keep the search focused on story header text nodes to avoid false positives from unrelated controls.
        const nodes = Array.from(document.querySelectorAll("header span, header a, header [role='button'], [data-testid*='story'] span, [data-testid*='story'] a"));
        for (const node of nodes) {
          if (!isVisible(node)) continue;
          if (!inStoryHeaderZone(node)) continue;

          const text = norm(node.innerText || node.textContent);
          const aria = norm(node.getAttribute && node.getAttribute("aria-label"));
          if (text.length > 60 && aria.length > 60) continue;

          const marker = matchesExplicitMarker(text) || matchesExplicitMarker(aria);
          if (!marker) continue;

          out.ad_detected = true;
          out.reason = "header_marker_match";
          out.marker_text = text || aria || marker;
          return out;
        }

        // Backup detector: scan concise visible labels in the top story zone.
        // This catches some sponsored labels that are not rendered inside <header>.
        const topNodes = Array.from(document.querySelectorAll("span, a, div, button")).filter((node) => {
          if (!isVisible(node)) return false;
          if (!inStoryHeaderZone(node)) return false;
          const text = norm(node.innerText || node.textContent);
          if (!text || text.length > 42) return false;
          return true;
        });

        for (const node of topNodes) {
          const text = norm(node.innerText || node.textContent);
          const aria = norm(node.getAttribute && node.getAttribute("aria-label"));
          const title = norm(node.getAttribute && node.getAttribute("title"));
          const candidate = [text, aria, title].find((value) => value && markerRegex.test(value));
          if (!candidate) continue;

          out.ad_detected = true;
          out.reason = "top_zone_marker_match";
          out.marker_text = candidate;
          return out;
        }

        return out;
      JS

      return { ad_detected: false, reason: "", marker_text: "", signal_source: "", signal_confidence: "", debug_hint: "" } unless payload.is_a?(Hash)

      result = {
        ad_detected: ActiveModel::Type::Boolean.new.cast(payload["ad_detected"]),
        reason: payload["reason"].to_s,
        marker_text: payload["marker_text"].to_s,
        signal_source: "dom_header",
        signal_confidence: "high",
        debug_hint: ""
      }
      return result if result[:ad_detected]

      media_url = media.is_a?(Hash) ? media[:url].to_s : ""
      media_hint = ad_hint_from_media_url(media_url)
      return result.merge(signal_source: "", signal_confidence: "", debug_hint: "") if media_hint.blank?

      if media_hint[:confidence] == "high"
        {
          ad_detected: true,
          reason: "media_url_ad_marker",
          marker_text: media_hint[:marker].to_s,
          signal_source: "media_url",
          signal_confidence: media_hint[:confidence].to_s,
          debug_hint: media_hint[:marker].to_s
        }
      else
        {
          ad_detected: false,
          reason: "",
          marker_text: "",
          signal_source: "media_url",
          signal_confidence: media_hint[:confidence].to_s,
          debug_hint: media_hint[:marker].to_s
        }
      end
    rescue StandardError
      { ad_detected: false, reason: "", marker_text: "", signal_source: "", signal_confidence: "", debug_hint: "" }
    end

    def detect_story_external_profile_link_context(driver:, current_username:)
      current = normalize_username(current_username).to_s
      payload = driver.execute_script(<<~JS, current)
        const currentUsername = (arguments[0] || "").toString().trim().toLowerCase();
        const out = { has_external_profile_link: false, linked_username: "", linked_profile_url: "", marker_text: "" };
        const norm = (value) => (value || "").toString().replace(/\\s+/g, " ").trim();
        const normLower = (value) => norm(value).toLowerCase();
        const isVisible = (el) => {
          if (!el) return false;
          const s = window.getComputedStyle(el);
          if (!s || s.display === "none" || s.visibility === "hidden" || s.opacity === "0") return false;
          const r = el.getBoundingClientRect();
          if (r.width < 8 || r.height < 8) return false;
          return r.bottom > 0 && r.top < window.innerHeight;
        };
        const parseLinkedUsername = (href) => {
          try {
            const u = new URL(href, window.location.origin);
            if (!/instagram\\.com$/i.test(u.hostname)) return "";
            const segs = u.pathname.split("/").filter(Boolean);
            if (segs.length !== 1) return "";
            const candidate = (segs[0] || "").toLowerCase();
            if (!/^[a-z0-9._]{1,30}$/.test(candidate)) return "";
            return candidate;
          } catch (e) {
            return "";
          }
        };

        const candidates = Array.from(document.querySelectorAll("a[href], [role='link'][href], [role='link'][data-href]"));
        for (const el of candidates) {
          if (!isVisible(el)) continue;
          const href = (el.getAttribute("href") || el.getAttribute("data-href") || "").toString();
          if (!href) continue;
          const linked = parseLinkedUsername(href);
          if (!linked) continue;
          if (linked === currentUsername) continue;

          const text = norm(el.innerText || el.textContent);
          const aria = norm(el.getAttribute && el.getAttribute("aria-label"));
          const title = norm(el.getAttribute && el.getAttribute("title"));
          const marker = [text, aria, title].find((v) => v && v.length > 0) || linked;
          const markerLower = normLower(marker);

          // Ignore common mention-style links; they do not necessarily indicate reshared content.
          if (markerLower.startsWith("@")) continue;
          if (markerLower.includes("mention")) continue;

          out.has_external_profile_link = true;
          out.linked_username = linked;
          out.linked_profile_url = href;
          out.marker_text = marker;
          return out;
        }

        return out;
      JS

      return { has_external_profile_link: false, linked_username: "", linked_profile_url: "", marker_text: "" } unless payload.is_a?(Hash)

      {
        has_external_profile_link: ActiveModel::Type::Boolean.new.cast(payload["has_external_profile_link"]),
        linked_username: payload["linked_username"].to_s,
        linked_profile_url: payload["linked_profile_url"].to_s,
        marker_text: payload["marker_text"].to_s
      }
    rescue StandardError
      { has_external_profile_link: false, linked_username: "", linked_profile_url: "", marker_text: "" }
    end

    def ad_hint_from_media_url(url)
      value = url.to_s.strip
      return nil if value.blank?

      down = value.downcase
      return { marker: "_nc_ad_query", confidence: "low" } if down.include?("_nc_ad=")
      return { marker: "ad_image_marker", confidence: "high" } if down.include?("ad_image")
      return { marker: "ads_image_marker", confidence: "high" } if down.include?("ads_image")
      return { marker: "ad_urlgen_marker", confidence: "high" } if down.include?("ad_urlgen")
      return { marker: "page_instagram_web_story_marker", confidence: "low" } if down.include?("page_instagram_web_story")

      uri = URI.parse(value)
      query = Rack::Utils.parse_query(uri.query.to_s)
      raw_efg = query["efg"].to_s
      return nil if raw_efg.blank?

      decoded = decode_urlsafe_base64(raw_efg)
      return nil if decoded.blank?

      text = decoded.downcase
      return { marker: "efg_ad_image", confidence: "high" } if text.include?("ad_image")
      return { marker: "efg_ads_image", confidence: "high" } if text.include?("ads_image")
      return { marker: "efg_ad_urlgen", confidence: "high" } if text.include?("ad_urlgen")
      return { marker: "efg_page_instagram_web_story", confidence: "low" } if text.include?("page_instagram_web_story")

      nil
    rescue StandardError
      nil
    end

    def decode_urlsafe_base64(value)
      src = value.to_s.tr("-_", "+/")
      src += "=" * ((4 - (src.length % 4)) % 4)
      Base64.decode64(src)
    rescue StandardError
      nil
    end

    def bool(value)
      ActiveModel::Type::Boolean.new.cast(value)
    end

    def normalize_same_site(value)
      token = value.to_s.strip.downcase
      return nil if token.blank?

      case token
      when "lax" then "Lax"
      when "strict" then "Strict"
      when "none", "no_restriction" then "None"
      end
    end

    def logged_out_page?(driver)
      body = driver.page_source.to_s.downcase
      body.include?("create an account or log in to instagram") ||
        body.include?("\"is_logged_in\":false") ||
        driver.find_elements(css: "input[name='username']").any?
    rescue StandardError
      false
    end

    def dismiss_common_overlays!(driver)
      # Best-effort: these overlays can prevent story tray elements from being inserted in the DOM.
      dismiss_texts = [
        "Allow all cookies",
        "Accept all",
        "Only allow essential cookies",
        "Not now",
        "Not Now"
      ]

      dismiss_texts.each do |text|
        button = driver.find_elements(xpath: "//button[normalize-space()='#{text}']").first
        next unless button&.displayed?

        button.click
        sleep(0.3)
      rescue StandardError
        next
      end
    end

    def js_click(driver, element)
      driver.execute_script(<<~JS, element)
        const el = arguments[0];
        if (!el) return false;
        try { el.scrollIntoView({ block: "center", inline: "nearest" }); } catch (e) {}
        try { el.click(); return true; } catch (e) {}
        return false;
      JS
    end

    def read_web_storage(driver, storage_name)
      script = <<~JS
        const s = window[#{storage_name.inspect}];
        const out = [];
        for (let i = 0; i < s.length; i++) {
          const k = s.key(i);
          out.push({ key: k, value: s.getItem(k) });
        }
        return out;
      JS
      driver.execute_script(script).map { |entry| entry.transform_keys(&:to_s) }
    rescue StandardError
      []
    end

    def write_web_storage(driver, storage_name, entries)
      safe_entries = Array(entries).map do |entry|
        entry = entry.to_h
        { "key" => entry["key"] || entry[:key], "value" => entry["value"] || entry[:value] }
      end.select { |e| e["key"].present? }

      script = <<~JS
        const s = window[#{storage_name.inspect}];
        const entries = arguments[0] || [];
        for (const e of entries) {
          try { s.setItem(e.key, e.value); } catch (err) {}
        }
        return entries.length;
      JS
      driver.execute_script(script, safe_entries)
    rescue StandardError
      nil
    end








  end
end
