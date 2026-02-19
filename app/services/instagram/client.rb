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
      return { valid: false, message: "No cookies stored" } if @account.cookies.empty?

      with_driver(headless: true) do |driver|
        driver.navigate.to(INSTAGRAM_BASE_URL)
        wait_for(driver, css: "body", timeout: 12)
        
        # Check if we're still logged in by looking for authentication indicators
        current_url = driver.current_url
        
        # If redirected to login page, session is invalid
        if current_url.include?("/accounts/login/") || current_url.include?("/accounts/emailsignup/")
          return { valid: false, message: "Session expired - redirected to login page" }
        end
        
        # Look for reliable signs of authenticated session
        begin
          # Check for reliable authenticated user elements based on actual testing
          authenticated_selectors = [
            "svg[aria-label='Home']",           # Home icon in navigation
            "svg[aria-label='Search']",          # Search icon in navigation  
            "img[alt*='profile picture']",       # Profile pictures (multiple elements)
            "a[href*='/direct/inbox/']",        # Direct messages/inbox link
            "[aria-label='Settings']",           # Settings icon/menu
            ".x9f619",                         # Common Instagram class for UI elements
            ".x78zum5",                        # Another common Instagram class
            ".x1i10hfl"                        # Interactive elements class
          ]
          
          authenticated_found = 0
          found_selectors = []
          
          authenticated_selectors.each do |selector|
            begin
              elements = driver.find_elements(css: selector)
              visible_elements = elements.select(&:displayed?)
              if visible_elements.any?
                authenticated_found += 1
                found_selectors << "#{selector} (#{visible_elements.length})"
              end
            rescue Selenium::WebDriver::Error::NoSuchElementError, Selenium::WebDriver::Error::StaleElementReferenceError
              # Continue checking other elements
            rescue StandardError => e
              # Log unexpected errors but continue
              Rails.logger.warn "Validation selector error for #{selector}: #{e.message}" if defined?(Rails)
            end
          end
          
          # Require at least 3 different authentication indicators to be confident
          min_required_indicators = 3
          
          if authenticated_found >= min_required_indicators
            # Additional verification: try to access the user's profile page
            original_url = driver.current_url
            driver.navigate.to("#{INSTAGRAM_BASE_URL}/#{@account.username}/")
            wait_for(driver, css: "body", timeout: 8)
            
            # Check if we can see the profile (not redirected to login)
            final_url = driver.current_url
            if final_url.include?("/accounts/login/")
              return { valid: false, message: "Session invalid - cannot access profile page" }
            end
            
            # Check for profile-specific elements
            profile_indicators = [
              "img[alt*='profile picture']",
              "h2",                           # Profile name header
              "a[href*='/followers/']",        # Followers link
              "a[href*='/following/']"         # Following link
            ]
            
            profile_elements_found = 0
            profile_indicators.each do |selector|
              begin
                elements = driver.find_elements(css: selector)
                visible_elements = elements.select(&:displayed?)
                profile_elements_found += 1 if visible_elements.any?
              rescue
                # Continue checking
              end
            end
            
            return { 
              valid: true, 
              message: "Session is valid and authenticated (found #{authenticated_found}/#{authenticated_selectors.length} indicators, #{profile_elements_found} profile elements)",
              details: {
                homepage_indicators: authenticated_found,
                profile_indicators: profile_elements_found,
                found_selectors: found_selectors
              }
            }
          else
            return { 
              valid: false, 
              message: "Session appears to be invalid - only found #{authenticated_found}/#{authenticated_selectors.length} authentication indicators",
              details: {
                homepage_indicators: authenticated_found,
                required_indicators: min_required_indicators,
                found_selectors: found_selectors
              }
            }
          end
          
        rescue StandardError => e
          return { valid: false, message: "Session validation error: #{e.message}" }
        end
      end
    rescue StandardError => e
      { valid: false, message: "Validation failed: #{e.message}" }
    end

    def sync_data!
      with_recoverable_session(label: "sync") do
        with_authenticated_driver do |driver|
          conversation_users = collect_conversation_users(driver)
          story_users = collect_story_users(driver)

          usernames = (conversation_users.keys + story_users.keys).uniq

          usernames.each do |username|
            # If a user is present in the inbox conversation list, this account can message them
            # (at minimum within the existing thread). Profile-based heuristics can be flaky.
            eligibility =
              if conversation_users.key?(username)
                { can_message: true, restriction_reason: nil }
              else
                fetch_eligibility(driver, username)
              end

            recipient = @account.recipients.find_or_initialize_by(username: username)
            recipient.display_name = conversation_users.dig(username, :display_name) || story_users.dig(username, :display_name) || username
            recipient.source = source_for(username, conversation_users, story_users)
            recipient.story_visible = story_users.key?(username)
            recipient.can_message = eligibility[:can_message]
            recipient.restriction_reason = eligibility[:restriction_reason]
            recipient.save!

            peer = @account.conversation_peers.find_or_initialize_by(username: username)
            peer.display_name = recipient.display_name
            peer.last_message_at = Time.current
            peer.save!
          end

          @account.update!(last_synced_at: Time.current)

          {
            recipients: @account.recipients.count,
            eligible: @account.recipients.eligible.count
          }
        end
      end
    end

    # Primary sync: followers/following lists (plus inbox to mark known-messageable threads).
    #
    # Returns stats hash suitable for storing in SyncRun.
    def sync_follow_graph!
      with_recoverable_session(label: "sync_follow_graph") do
        with_authenticated_driver do |driver|
          raise "Instagram username must be set on the account before syncing" if @account.username.blank?

          conversation_users = collect_conversation_users(driver)
          story_users = collect_story_users(driver)

          followers = collect_follow_list(driver, list_kind: :followers, profile_username: @account.username)
          following = collect_follow_list(driver, list_kind: :following, profile_username: @account.username)

          follower_usernames = followers.keys
          following_usernames = following.keys
          mutuals = (follower_usernames & following_usernames)

          InstagramProfile.transaction do
            # Reset follow flags before applying the latest graph.
            @account.instagram_profiles.update_all(following: false, follows_you: false)

            upsert_follow_list!(followers, following_flag: false, follows_you_flag: true)
            upsert_follow_list!(following, following_flag: true, follows_you_flag: false)

            # Mark mutuals explicitly via flags (already set from above).
            @account.instagram_profiles.where(username: mutuals).update_all(last_synced_at: Time.current)

            # Inbox-derived messageability is our most reliable signal.
            messageable_usernames = conversation_users.keys
            @account.instagram_profiles.where(username: messageable_usernames).update_all(
              can_message: true,
              restriction_reason: nil,
              dm_interaction_state: "messageable",
              dm_interaction_reason: "inbox_thread_seen",
              dm_interaction_checked_at: Time.current,
              dm_interaction_retry_after_at: nil
            )
          end

          # "Last active" signal: story tray visibility (approximate; we only know it was visible now).
          now = Time.current
          story_users.keys.each do |username|
            profile = @account.instagram_profiles.find_by(username: username)
            next unless profile

            profile.last_story_seen_at = now
            profile.recompute_last_active!
            profile.save!

            profile.record_event!(
              kind: "story_seen",
              external_id: "story_seen:#{now.utc.to_date.iso8601}",
              occurred_at: nil,
              metadata: { source: "home_story_tray" }
            )
          end

          @account.update!(last_synced_at: Time.current)

          {
            followers: follower_usernames.length,
            following: following_usernames.length,
            mutuals: mutuals.length,
            conversation_threads: conversation_users.length,
            profiles_total: @account.instagram_profiles.count,
            story_tray_visible: story_users.length
          }
        end
      end
    end

    # Captures "home feed" post identifiers that appear while scrolling.
    #
    # This does NOT auto-like or auto-comment. It only records posts, downloads media (temporarily),
    # and queues analysis. Interaction should remain a user-confirmed action in the UI.
    def capture_home_feed_posts!(rounds: 4, delay_seconds: 45, max_new: 20)
      with_recoverable_session(label: "feed_capture") do
        with_authenticated_driver do |driver|
          with_task_capture(driver: driver, task_name: "feed_capture_home", meta: { rounds: rounds, delay_seconds: delay_seconds, max_new: max_new }) do
            driver.navigate.to(INSTAGRAM_BASE_URL)
            wait_for(driver, css: "body", timeout: 12)
            dismiss_common_overlays!(driver)

            seen = 0
            new_posts = 0

            rounds.to_i.clamp(1, 25).times do |i|
              dismiss_common_overlays!(driver)

              items = extract_feed_items_from_dom(driver)
              now = Time.current

              items.each do |it|
                sc = it[:shortcode].to_s.strip
                next if sc.blank?

                seen += 1

                post = @account.instagram_posts.find_or_initialize_by(shortcode: sc)
                is_new = post.new_record?

                post.detected_at ||= now
                post.post_kind = it[:post_kind].presence || post.post_kind.presence || "unknown"
                post.author_username = it[:author_username].presence || post.author_username
                post.media_url = it[:media_url].presence || post.media_url
                post.caption = it[:caption].presence || post.caption
                post.metadata = (post.metadata || {}).merge(it[:metadata] || {}).merge(round: i + 1)
                post.save! if post.changed?

                if is_new
                  new_posts += 1

                  # Download media and analyze (best effort).
                  DownloadInstagramPostMediaJob.perform_later(instagram_post_id: post.id) if post.media_url.present?
                  AnalyzeInstagramPostJob.perform_later(instagram_post_id: post.id)
                end

                break if new_posts >= max_new.to_i.clamp(1, 200)
              end

              break if new_posts >= max_new.to_i.clamp(1, 200)

              # Scroll down a bit.
              driver.execute_script("window.scrollBy(0, Math.max(700, window.innerHeight * 0.85));")
              sleep(delay_seconds.to_i.clamp(10, 120))
            end

            { seen_posts: seen, new_posts: new_posts }
          end
        end
      end
    end

    # Full Selenium automation flow:
    # - navigate home feed
    # - optionally engage one story first (hold/freeze until reply)
    # - find image posts, download media, store profile history, analyze, generate comment, post first suggestion
    # - capture HTML/JSON/screenshot artifacts at each step
    def auto_engage_home_feed!(max_posts: 3, include_story: true, story_hold_seconds: 18)
      max_posts_i = max_posts.to_i.clamp(1, 10)
      include_story_bool = ActiveModel::Type::Boolean.new.cast(include_story)
      hold_seconds_i = story_hold_seconds.to_i.clamp(8, 40)

      with_recoverable_session(label: "auto_engage_home_feed") do
        with_authenticated_driver do |driver|
          with_task_capture(
            driver: driver,
            task_name: "auto_engage_home_feed_start",
            meta: { max_posts: max_posts_i, include_story: include_story_bool, story_hold_seconds: hold_seconds_i }
          ) do
            driver.navigate.to(INSTAGRAM_BASE_URL)
            wait_for(driver, css: "body", timeout: 12)
            dismiss_common_overlays!(driver)
            capture_task_html(driver: driver, task_name: "auto_engage_home_loaded", status: "ok")

            story_result =
              if include_story_bool
                auto_engage_first_story!(driver: driver, story_hold_seconds: hold_seconds_i)
              else
                { attempted: false, replied: false }
              end

            driver.navigate.to(INSTAGRAM_BASE_URL)
            wait_for(driver, css: "body", timeout: 12)
            dismiss_common_overlays!(driver)
            sleep(0.6)
            capture_task_html(driver: driver, task_name: "auto_engage_home_before_posts", status: "ok")

            feed_items = extract_feed_items_from_dom(driver).select do |item|
              item[:post_kind] == "post" &&
                item[:shortcode].to_s.present? &&
                item[:media_url].to_s.start_with?("http://", "https://")
            end
            capture_task_html(
              driver: driver,
              task_name: "auto_engage_posts_discovered",
              status: "ok",
              meta: { discovered_posts: feed_items.length, max_posts: max_posts_i }
            )

            processed = 0
            commented = 0
            details = []

            feed_items.each do |item|
              break if processed >= max_posts_i
              processed += 1

              begin
                result = auto_engage_feed_post!(driver: driver, item: item)
                details << result
                commented += 1 if result[:comment_posted] == true
              rescue StandardError => e
                details << {
                  shortcode: item[:shortcode],
                  username: item[:author_username],
                  comment_posted: false,
                  error: e.message.to_s
                }
              end
            end

            {
              story_replied: story_result[:replied] == true,
              posts_commented: commented,
              posts_processed: processed,
              details: details
            }
          end
        end
      end
    end

    # Homepage carousel-based story sync:
    # - open home page and story tray
    # - process up to N stories from carousel using "Next" button
    # - for image stories: download, store, analyze, (optional) post generated comment
    # - for video stories: download + persist to ActiveStorage and ingest for later processing
    # - capture per-step HTML/JSON/screenshot artifacts for DOM troubleshooting
    def sync_home_story_carousel!(story_limit: 10, auto_reply_only: false)
      limit = story_limit.to_i.clamp(1, 50)
      tagged_only = ActiveModel::Type::Boolean.new.cast(auto_reply_only)

      with_recoverable_session(label: "sync_home_story_carousel") do
        with_authenticated_driver do |driver|
          with_task_capture(
            driver: driver,
            task_name: "home_story_sync_start",
            meta: { story_limit: limit, auto_reply_only: tagged_only }
          ) do
            driver.navigate.to(INSTAGRAM_BASE_URL)
            wait_for(driver, css: "body", timeout: 12)
            dismiss_common_overlays!(driver)
            capture_task_html(driver: driver, task_name: "home_story_sync_home_loaded", status: "ok")

            open_first_story_from_home_carousel!(driver: driver)

            wait_for(driver, css: "body", timeout: 12)
            freeze_story_progress!(driver)
            capture_task_html(driver: driver, task_name: "home_story_sync_opened_first_story", status: "ok")

            stats = { stories_visited: 0, downloaded: 0, analyzed: 0, commented: 0, reacted: 0, skipped_video: 0, skipped_not_tagged: 0, skipped_ads: 0, skipped_invalid_media: 0, skipped_unreplyable: 0, skipped_out_of_network: 0, skipped_interaction_retry: 0, skipped_reshared_external_link: 0, failed: 0 }
            visited_refs = {}
            story_api_cache = {}
            safety_limit = limit * 5
            exit_reason = "safety_limit_exhausted"
            account_profile = find_or_create_profile_for_auto_engagement!(username: @account.username)
            started_at = Time.current
            account_profile.record_event!(
              kind: "story_sync_started",
              external_id: "story_sync_started:home_carousel:#{started_at.utc.iso8601(6)}",
              occurred_at: started_at,
              metadata: { source: "home_story_carousel", story_limit: limit, auto_reply_only: tagged_only }
            )

            safety_limit.times do
              if stats[:stories_visited] >= limit
                exit_reason = "limit_reached"
                break
              end

              context = normalized_story_context_for_processing(driver: driver, context: current_story_context(driver))
              if context[:story_url_recovery_needed]
                recover_story_url_context!(driver: driver, username: context[:username], reason: "fallback_profile_url")
                context = normalized_story_context_for_processing(driver: driver, context: current_story_context(driver))
              end

              ref = context[:ref].presence || context[:story_key].to_s
              if ref.blank?
                capture_task_html(
                  driver: driver,
                  task_name: "home_story_sync_story_context_missing",
                  status: "error",
                  meta: {
                    current_url: driver.current_url.to_s,
                    page_title: driver.title.to_s,
                    resolved_username: context[:username],
                    resolved_story_id: context[:story_id]
                  }
                )
                fallback_username = context[:username].presence || @account.username.to_s
                if fallback_username.present?
                  fallback_profile = find_or_create_profile_for_auto_engagement!(username: fallback_username)
                  fallback_profile.record_event!(
                    kind: "story_sync_failed",
                    external_id: "story_sync_failed:context_missing:#{Time.current.utc.iso8601(6)}",
                    occurred_at: Time.current,
                    metadata: {
                      source: "home_story_carousel",
                      reason: "story_context_missing",
                      current_url: driver.current_url.to_s,
                      page_title: driver.title.to_s
                    }
                  )
                end
                exit_reason = "story_context_missing"
                break
              end
              story_key = context[:story_key].presence || ref
              if visited_refs[story_key]
                capture_task_html(
                  driver: driver,
                  task_name: "home_story_sync_duplicate_story_key",
                  status: "error",
                  meta: {
                    story_key: story_key,
                    ref: ref,
                    current_url: driver.current_url.to_s
                  }
                )
                moved = click_next_story_in_carousel!(driver: driver, current_ref: ref)
                if moved
                  next
                end
                exit_reason = "duplicate_story_key_no_progress"
                break
              end
              visited_refs[story_key] = true
              story_id = normalize_story_id_token(context[:story_id])
              story_id = normalize_story_id_token(ref.to_s.split(":")[1].to_s) if story_id.blank?
              story_id = normalize_story_id_token(current_story_reference(driver.current_url.to_s).to_s.split(":")[1].to_s) if story_id.blank?
              story_url = canonical_story_url(
                username: context[:username],
                story_id: story_id,
                fallback_url: driver.current_url.to_s
              )

              stats[:stories_visited] += 1
              freeze_story_progress!(driver)
              capture_task_html(
                driver: driver,
                task_name: "home_story_sync_story_loaded",
                status: "ok",
                meta: { ref: ref, story_key: story_key, username: context[:username], story_id: story_id, current_url: story_url }
              )

              if story_id.blank?
                stats[:failed] += 1
                fallback_profile = find_or_create_profile_for_auto_engagement!(username: context[:username].presence || @account.username.to_s)
                fallback_profile.record_event!(
                  kind: "story_sync_failed",
                  external_id: "story_sync_failed:missing_story_id:#{Time.current.utc.iso8601(6)}",
                  occurred_at: Time.current,
                  metadata: {
                    source: "home_story_carousel",
                    reason: "story_id_unresolved",
                    story_ref: ref,
                    story_key: story_key,
                    story_url: story_url
                  }
                )
                moved = click_next_story_in_carousel!(driver: driver, current_ref: ref)
                unless moved
                  exit_reason = "next_navigation_failed"
                  break
                end
                next
              end

              profile = find_story_network_profile(username: context[:username])
              if profile.nil?
                stats[:skipped_out_of_network] += 1
                account_profile.record_event!(
                  kind: "story_reply_skipped",
                  external_id: "story_reply_skipped:#{story_id}:#{Time.current.utc.iso8601(6)}",
                  occurred_at: Time.current,
                  metadata: {
                    source: "home_story_carousel",
                    story_id: story_id,
                    story_ref: ref,
                    story_url: story_url,
                    reason: "profile_not_in_network",
                    status: "Out of network",
                    username: context[:username].to_s
                  }
                )
                capture_task_html(
                  driver: driver,
                  task_name: "home_story_sync_out_of_network_skipped",
                  status: "ok",
                  meta: {
                    story_id: story_id,
                    story_ref: ref,
                    username: context[:username].to_s,
                    reason: "profile_not_in_network"
                  }
                )
                moved = click_next_story_in_carousel!(driver: driver, current_ref: ref)
                unless moved
                  exit_reason = "next_navigation_failed"
                  break
                end
                next
              end

              if profile_interaction_retry_pending?(profile)
                stats[:skipped_interaction_retry] += 1
                stats[:skipped_unreplyable] += 1
                profile.record_event!(
                  kind: "story_reply_skipped",
                  external_id: "story_reply_skipped:#{story_id}:#{Time.current.utc.iso8601(6)}",
                  occurred_at: Time.current,
                  metadata: {
                    source: "home_story_carousel",
                    story_id: story_id,
                    story_ref: ref,
                    story_url: story_url,
                    reason: "interaction_retry_window_active",
                    status: "Interaction unavailable (retry pending)",
                    retry_after_at: profile.story_interaction_retry_after_at&.iso8601,
                    interaction_state: profile.story_interaction_state.to_s,
                    interaction_reason: profile.story_interaction_reason.to_s
                  }
                )
                capture_task_html(
                  driver: driver,
                  task_name: "home_story_sync_interaction_retry_skipped",
                  status: "ok",
                  meta: {
                    story_id: story_id,
                    story_ref: ref,
                    retry_after_at: profile.story_interaction_retry_after_at&.iso8601,
                    interaction_state: profile.story_interaction_state.to_s,
                    interaction_reason: profile.story_interaction_reason.to_s
                  }
                )
                moved = click_next_story_in_carousel!(driver: driver, current_ref: ref)
                unless moved
                  exit_reason = "next_navigation_failed"
                  break
                end
                next
              end

              media = resolve_story_media_for_current_context(
                driver: driver,
                username: context[:username],
                story_id: story_id,
                fallback_story_key: story_key,
                cache: story_api_cache
              )
              if media[:url].to_s.blank?
                stats[:failed] += 1
                profile.record_event!(
                  kind: "story_sync_failed",
                  external_id: "story_sync_failed:#{story_id}:#{Time.current.utc.iso8601(6)}",
                  occurred_at: Time.current,
                  metadata: {
                    source: "home_story_carousel",
                    reason: "api_story_media_unavailable",
                    story_id: story_id,
                    story_ref: ref,
                    story_url: story_url,
                    media_source: media[:source].to_s,
                    media_variant_count: media[:media_variant_count].to_i
                  }
                )
                moved = click_next_story_in_carousel!(driver: driver, current_ref: ref)
                unless moved
                  exit_reason = "next_navigation_failed"
                  break
                end
                next
              end

              media_story_id_hint = story_id_hint_from_media_url(media[:url])
              if media_story_id_hint.present? && media_story_id_hint != story_id
                stats[:failed] += 1
                profile.record_event!(
                  kind: "story_sync_failed",
                  external_id: "story_sync_failed:#{story_id}:#{Time.current.utc.iso8601(6)}",
                  occurred_at: Time.current,
                  metadata: {
                    source: "home_story_carousel",
                    reason: "story_media_story_id_mismatch",
                    expected_story_id: story_id,
                    media_story_id: media_story_id_hint,
                    story_ref: ref,
                    story_url: story_url,
                    media_source: media[:source].to_s,
                    media_url: media[:url].to_s
                  }
                )
                moved = click_next_story_in_carousel!(driver: driver, current_ref: ref)
                unless moved
                  exit_reason = "next_navigation_failed"
                  break
                end
                next
              end
              ad_context = detect_story_ad_context(driver: driver, media: media)
              capture_task_html(
                driver: driver,
                task_name: "home_story_sync_story_probe",
                status: "ok",
                meta: {
                  story_id: story_id,
                  story_ref: ref,
                  story_key: story_key,
                  username: context[:username],
                  ad_detected: ad_context[:ad_detected],
                  ad_reason: ad_context[:reason],
                  ad_marker_text: ad_context[:marker_text],
                  ad_signal_source: ad_context[:signal_source],
                  ad_signal_confidence: ad_context[:signal_confidence],
                  ad_debug_hint: ad_context[:debug_hint],
                  media_source: media[:source],
                  media_type: media[:media_type],
                  media_url: media[:url].to_s.byteslice(0, 500),
                  media_width: media[:width],
                  media_height: media[:height],
                  media_variant_count: media[:media_variant_count].to_i,
                  primary_media_source: media[:primary_media_source].to_s,
                  primary_media_index: media[:primary_media_index],
                  carousel_media_count: Array(media[:carousel_media]).length
                }
              )
              if ad_context[:ad_detected]
                stats[:skipped_ads] += 1
                profile.record_event!(
                  kind: "story_ad_skipped",
                  external_id: "story_ad_skipped:#{story_id}:#{Time.current.utc.iso8601(6)}",
                  occurred_at: Time.current,
                  metadata: {
                    source: "home_story_carousel",
                    story_id: story_id,
                    story_ref: ref,
                    story_url: story_url,
                    reason: ad_context[:reason],
                    marker_text: ad_context[:marker_text]
                  }
                )
                capture_task_html(
                  driver: driver,
                  task_name: "home_story_sync_ad_skipped",
                  status: "ok",
                  meta: {
                    story_id: story_id,
                    story_ref: ref,
                    reason: ad_context[:reason],
                    marker_text: ad_context[:marker_text]
                  }
                )
                moved = click_next_story_in_carousel!(driver: driver, current_ref: ref)
                unless moved
                  exit_reason = "next_navigation_failed"
                  break
                end
                next
              end

              api_external_context = story_external_profile_link_context_from_api(
                username: context[:username],
                story_id: story_id,
                cache: story_api_cache
              )
              if api_external_context[:known] && api_external_context[:has_external_profile_link]
                stats[:skipped_reshared_external_link] += 1
                profile.record_event!(
                  kind: "story_reply_skipped",
                  external_id: "story_reply_skipped:#{story_id}:#{Time.current.utc.iso8601(6)}",
                  occurred_at: Time.current,
                  metadata: {
                    source: "home_story_carousel",
                    story_id: story_id,
                    story_ref: ref,
                    story_url: story_url,
                    reason: api_external_context[:reason_code].to_s.presence || "api_external_profile_indicator",
                    status: "External attribution detected (API)",
                    linked_username: api_external_context[:linked_username],
                    linked_profile_url: api_external_context[:linked_profile_url],
                    marker_text: api_external_context[:marker_text],
                    linked_targets: Array(api_external_context[:linked_targets])
                  }
                )
                capture_task_html(
                  driver: driver,
                  task_name: "home_story_sync_external_profile_link_skipped",
                  status: "ok",
                  meta: {
                    story_id: story_id,
                    story_ref: ref,
                    linked_username: api_external_context[:linked_username],
                    linked_profile_url: api_external_context[:linked_profile_url],
                    marker_text: api_external_context[:marker_text],
                    linked_targets: Array(api_external_context[:linked_targets]),
                    reason_code: api_external_context[:reason_code]
                  }
                )
                moved = click_next_story_in_carousel!(driver: driver, current_ref: ref)
                unless moved
                  exit_reason = "next_navigation_failed"
                  break
                end
                next
              end

              api_reply_gate = story_reply_capability_from_api(username: context[:username], story_id: story_id)
              if api_reply_gate[:known] && api_reply_gate[:reply_possible] == false
                stats[:skipped_unreplyable] += 1
                retry_after = Time.current + STORY_INTERACTION_RETRY_DAYS.days
                mark_profile_interaction_state!(
                  profile: profile,
                  state: "unavailable",
                  reason: api_reply_gate[:reason_code].to_s.presence || "api_can_reply_false",
                  reaction_available: false,
                  retry_after_at: retry_after
                )
                profile.record_event!(
                  kind: "story_reply_skipped",
                  external_id: "story_reply_skipped:#{story_id}:#{Time.current.utc.iso8601(6)}",
                  occurred_at: Time.current,
                  metadata: {
                    source: "home_story_carousel",
                    story_id: story_id,
                    story_ref: ref,
                    story_url: story_url,
                    reason: api_reply_gate[:reason_code],
                    status: api_reply_gate[:status],
                    retry_after_at: retry_after.iso8601
                  }
                )
                moved = click_next_story_in_carousel!(driver: driver, current_ref: ref)
                unless moved
                  exit_reason = "next_navigation_failed"
                  break
                end
                next
              end

              reply_gate =
                if api_reply_gate[:known] && api_reply_gate[:reply_possible] == true
                  { reply_possible: true, reason_code: nil, status: api_reply_gate[:status], marker_text: "", submission_reason: "api_can_reply_true" }
                else
                  check_story_reply_capability(driver: driver)
                end
              unless reply_gate[:reply_possible]
                reaction_result = react_to_story_if_available!(driver: driver)
                if reaction_result[:reacted]
                  stats[:reacted] += 1
                  mark_profile_interaction_state!(
                    profile: profile,
                    state: "reaction_only",
                    reason: reply_gate[:reason_code].to_s.presence || "reply_unavailable_reaction_available",
                    reaction_available: true
                  )
                  profile.record_event!(
                    kind: "story_reaction_sent",
                    external_id: "story_reaction_sent:#{story_id}:#{Time.current.utc.iso8601(6)}",
                    occurred_at: Time.current,
                    metadata: {
                      source: "home_story_carousel",
                      story_id: story_id,
                      story_ref: ref,
                      story_url: story_url,
                      reaction_reason: reaction_result[:reason],
                      reaction_marker_text: reaction_result[:marker_text],
                      reply_gate_reason: reply_gate[:reason_code]
                    }
                  )
                  capture_task_html(
                    driver: driver,
                    task_name: "home_story_sync_reaction_fallback_sent",
                    status: "ok",
                    meta: {
                      story_id: story_id,
                      story_ref: ref,
                      reaction_reason: reaction_result[:reason],
                      reaction_marker_text: reaction_result[:marker_text],
                      reply_gate_reason: reply_gate[:reason_code]
                    }
                  )
                  moved = click_next_story_in_carousel!(driver: driver, current_ref: ref)
                  unless moved
                    exit_reason = "next_navigation_failed"
                    break
                  end
                  next
                end

                stats[:skipped_unreplyable] += 1
                retry_after = Time.current + STORY_INTERACTION_RETRY_DAYS.days
                mark_profile_interaction_state!(
                  profile: profile,
                  state: "unavailable",
                  reason: reply_gate[:reason_code].to_s.presence || "reply_unavailable",
                  reaction_available: false,
                  retry_after_at: retry_after
                )
                profile.record_event!(
                  kind: "story_reply_skipped",
                  external_id: "story_reply_skipped:#{story_id}:#{Time.current.utc.iso8601(6)}",
                  occurred_at: Time.current,
                  metadata: {
                    source: "home_story_carousel",
                    story_id: story_id,
                    story_ref: ref,
                    story_url: story_url,
                    reason: reply_gate[:reason_code],
                    status: reply_gate[:status],
                    submission_reason: reply_gate[:submission_reason],
                    submission_marker_text: reply_gate[:marker_text],
                    retry_after_at: retry_after.iso8601,
                    reaction_fallback_attempted: true,
                    reaction_fallback_reason: reaction_result[:reason],
                    reaction_fallback_marker_text: reaction_result[:marker_text]
                  }
                )
                capture_task_html(
                  driver: driver,
                  task_name: "home_story_sync_reply_precheck_skipped",
                  status: "ok",
                  meta: {
                    story_id: story_id,
                    story_ref: ref,
                    reason: reply_gate[:reason_code],
                    status_text: reply_gate[:status],
                    marker_text: reply_gate[:marker_text],
                    retry_after_at: retry_after.iso8601,
                    reaction_fallback_reason: reaction_result[:reason],
                    reaction_fallback_marker_text: reaction_result[:marker_text]
                  }
                )
                moved = click_next_story_in_carousel!(driver: driver, current_ref: ref)
                unless moved
                  exit_reason = "next_navigation_failed"
                  break
                end
                next
              end
              mark_profile_interaction_state!(
                profile: profile,
                state: "reply_available",
                reason: "reply_box_found",
                reaction_available: nil,
                retry_after_at: nil
              )

              story_time = Time.current
              profile.record_event!(
                kind: "story_uploaded",
                external_id: "story_uploaded:#{story_id}",
                occurred_at: nil,
                metadata: {
                  source: "home_story_carousel",
                  story_id: story_id,
                  story_ref: ref,
                  story_url: story_url
                }
              )
              profile.record_event!(
                kind: "story_viewed",
                external_id: "story_viewed:#{story_id}:#{story_time.utc.iso8601(6)}",
                occurred_at: story_time,
                metadata: {
                  source: "home_story_carousel",
                  story_id: story_id,
                  story_ref: ref,
                  story_url: story_url
                }
              )

              if media[:media_type].to_s == "video"
                begin
                  download = download_media_with_metadata(url: media[:url], user_agent: @account.user_agent)
                  stats[:downloaded] += 1
                  now = Time.current
                  downloaded_event = profile.record_event!(
                    kind: "story_downloaded",
                    external_id: "story_downloaded:#{story_id}:#{now.utc.iso8601(6)}",
                    occurred_at: now,
                    metadata: {
                      source: "home_story_carousel",
                      story_id: story_id,
                      story_ref: ref,
                      story_url: story_url,
                      media_type: "video",
                      media_source: media[:source],
                      media_url: media[:url],
                      image_url: media[:image_url],
                      video_url: media[:video_url],
                      media_width: media[:width],
                      media_height: media[:height],
                      owner_user_id: media[:owner_user_id],
                      owner_username: media[:owner_username],
                      api_media_variant_count: media[:media_variant_count].to_i,
                      api_primary_media_source: media[:primary_media_source].to_s,
                      api_primary_media_index: media[:primary_media_index],
                      api_carousel_media: compact_story_media_variants_for_metadata(media[:carousel_media]),
                      media_content_type: download[:content_type],
                      media_bytes: download[:bytes].bytesize
                    }
                  )
                  downloaded_event.media.attach(io: StringIO.new(download[:bytes]), filename: download[:filename], content_type: download[:content_type])
                  InstagramProfileEvent.broadcast_story_archive_refresh!(account: @account)
                  StoryIngestionService.new(account: @account, profile: profile).ingest!(
                    story: {
                      story_id: story_id,
                      media_type: "video",
                      media_url: media[:url],
                      image_url: nil,
                      video_url: media[:url],
                      caption: nil,
                      permalink: story_url,
                      taken_at: story_time
                    },
                    source_event: downloaded_event,
                    bytes: download[:bytes],
                    content_type: download[:content_type],
                    filename: download[:filename]
                  )
                rescue StandardError => e
                  stats[:failed] += 1
                  profile.record_event!(
                    kind: "story_sync_failed",
                    external_id: "story_sync_failed:#{story_id}:#{Time.current.utc.iso8601(6)}",
                    occurred_at: Time.current,
                    metadata: { source: "home_story_carousel", story_ref: ref, error_class: e.class.name, error_message: e.message }
                  )
                end
                stats[:skipped_video] += 1
                next unless click_next_story_in_carousel!(driver: driver, current_ref: ref)
                next
              end

              duplicate_reply = story_already_replied?(
                profile: profile,
                story_id: story_id,
                story_ref: ref,
                story_url: story_url,
                media_url: media[:url]
              )
              if duplicate_reply[:found]
                profile.record_event!(
                  kind: "story_reply_skipped",
                  external_id: "story_reply_skipped:#{story_id}:#{Time.current.utc.iso8601(6)}",
                  occurred_at: Time.current,
                  metadata: {
                    source: "home_story_carousel",
                    story_id: story_id,
                    story_ref: ref,
                    story_url: story_url,
                    reason: "duplicate_story_already_replied",
                    matched_by: duplicate_reply[:matched_by],
                    matched_event_external_id: duplicate_reply[:matched_external_id]
                  }
                )
                capture_task_html(
                  driver: driver,
                  task_name: "home_story_sync_duplicate_reply_skipped",
                  status: "ok",
                  meta: {
                    story_id: story_id,
                    story_ref: ref,
                    matched_by: duplicate_reply[:matched_by],
                    matched_event_external_id: duplicate_reply[:matched_external_id]
                  }
                )
                moved = click_next_story_in_carousel!(driver: driver, current_ref: ref)
                unless moved
                  exit_reason = "next_navigation_failed"
                  break
                end
                next
              end

              begin
                download = download_media_with_metadata(url: media[:url], user_agent: @account.user_agent)
                stats[:downloaded] += 1
                quality = evaluate_story_image_quality(download: download, media: media)
                if quality[:skip]
                  stats[:skipped_invalid_media] += 1
                  profile.record_event!(
                    kind: "story_reply_skipped",
                    external_id: "story_reply_skipped:#{story_id}:#{Time.current.utc.iso8601(6)}",
                    occurred_at: Time.current,
                    metadata: {
                      source: "home_story_carousel",
                      story_id: story_id,
                      story_ref: ref,
                      story_url: story_url,
                      reason: "invalid_story_media",
                      quality_reason: quality[:reason],
                      quality_entropy: quality[:entropy],
                      media_type: media[:media_type],
                      media_width: media[:width],
                      media_height: media[:height],
                      media_content_type: download[:content_type],
                      media_bytes: download[:bytes].bytesize
                    }
                  )
                  capture_task_html(
                    driver: driver,
                    task_name: "home_story_sync_invalid_media_skipped",
                    status: "ok",
                    meta: {
                      story_id: story_id,
                      story_ref: ref,
                      quality_reason: quality[:reason],
                      quality_entropy: quality[:entropy],
                      media_content_type: download[:content_type],
                      media_bytes: download[:bytes].bytesize
                    }
                  )
                  moved = click_next_story_in_carousel!(driver: driver, current_ref: ref)
                  unless moved
                    exit_reason = "next_navigation_failed"
                    break
                  end
                  next
                end
                now = Time.current
                downloaded_event = profile.record_event!(
                  kind: "story_downloaded",
                  external_id: "story_downloaded:#{story_id}:#{now.utc.iso8601(6)}",
                  occurred_at: now,
                  metadata: {
                    source: "home_story_carousel",
                    story_id: story_id,
                    story_ref: ref,
                    story_url: story_url,
                    media_type: "image",
                    media_source: media[:source],
                    media_url: media[:url],
                    image_url: media[:image_url],
                    video_url: media[:video_url],
                    media_width: media[:width],
                    media_height: media[:height],
                    owner_user_id: media[:owner_user_id],
                    owner_username: media[:owner_username],
                    api_media_variant_count: media[:media_variant_count].to_i,
                    api_primary_media_source: media[:primary_media_source].to_s,
                    api_primary_media_index: media[:primary_media_index],
                    api_carousel_media: compact_story_media_variants_for_metadata(media[:carousel_media]),
                    media_content_type: download[:content_type],
                    media_bytes: download[:bytes].bytesize
                  }
                )
                downloaded_event.media.attach(io: StringIO.new(download[:bytes]), filename: download[:filename], content_type: download[:content_type])
                InstagramProfileEvent.broadcast_story_archive_refresh!(account: @account)

                payload = build_auto_engagement_post_payload(
                  profile: profile,
                  shortcode: story_id,
                  caption: nil,
                  permalink: story_url,
                  include_story_history: true
                )
                analysis = analyze_for_auto_engagement!(
                  analyzable: downloaded_event,
                  payload: payload,
                  bytes: download[:bytes],
                  content_type: download[:content_type],
                  source_url: media[:url]
                )
                stats[:analyzed] += 1 if analysis.present?

                suggestions = generate_comment_suggestions_from_analysis!(profile: profile, payload: payload, analysis: analysis)
                comment_text = suggestions.first.to_s.strip
                capture_task_html(
                  driver: driver,
                  task_name: "home_story_sync_comment_generation",
                  status: comment_text.present? ? "ok" : "error",
                  meta: { story_ref: ref, suggestions_count: suggestions.length, comment_preview: comment_text.byteslice(0, 120) }
                )

                if tagged_only && !profile_auto_reply_enabled?(profile)
                  stats[:skipped_not_tagged] += 1
                  profile.record_event!(
                    kind: "story_reply_skipped",
                    external_id: "story_reply_skipped:#{story_id}:#{Time.current.utc.iso8601(6)}",
                    occurred_at: Time.current,
                    metadata: { source: "home_story_carousel", story_id: story_id, story_ref: ref, story_url: story_url, reason: "missing_auto_reply_tag" }
                  )
                elsif comment_text.blank?
                  profile.record_event!(
                    kind: "story_reply_skipped",
                    external_id: "story_reply_skipped:#{story_id}:#{Time.current.utc.iso8601(6)}",
                    occurred_at: Time.current,
                    metadata: { source: "home_story_carousel", story_id: story_id, story_ref: ref, story_url: story_url, reason: "no_comment_generated" }
                  )
                else
                  comment_result = comment_on_story_via_api!(
                    story_id: story_id,
                    story_username: context[:username],
                    comment_text: comment_text
                  )
                  if !comment_result[:posted]
                    comment_result = comment_on_story_via_ui!(driver: driver, comment_text: comment_text)
                  end
                  posted = comment_result[:posted]
                  skip_status = story_reply_skip_status_for(comment_result)
                  capture_task_html(
                    driver: driver,
                    task_name: "home_story_sync_comment_submission",
                    status: posted ? "ok" : "error",
                    meta: {
                      story_ref: ref,
                      comment_preview: comment_text.byteslice(0, 120),
                      posted: posted,
                      submission_method: comment_result[:method],
                      failure_reason: comment_result[:reason],
                      skip_status: skip_status[:status],
                      skip_reason_code: skip_status[:reason_code]
                    }
                  )
                  if posted
                    stats[:commented] += 1
                    mark_profile_interaction_state!(
                      profile: profile,
                      state: "reply_available",
                      reason: "comment_sent",
                      reaction_available: nil,
                      retry_after_at: nil
                    )
                    profile.record_event!(
                      kind: "story_reply_sent",
                      external_id: "story_reply_sent:#{story_id}",
                      occurred_at: Time.current,
                      metadata: {
                        source: "home_story_carousel",
                        story_id: story_id,
                        story_ref: ref,
                        story_url: story_url,
                        media_url: media[:url],
                        comment_text: comment_text,
                        submission_method: comment_result[:method]
                      }
                    )
                    attach_reply_comment_to_downloaded_event!(downloaded_event: downloaded_event, comment_text: comment_text)
                  else
                    profile.record_event!(
                      kind: "story_reply_skipped",
                      external_id: "story_reply_skipped:#{story_id}:#{Time.current.utc.iso8601(6)}",
                      occurred_at: Time.current,
                      metadata: {
                        source: "home_story_carousel",
                        story_id: story_id,
                        story_ref: ref,
                        story_url: story_url,
                        reason: skip_status[:reason_code],
                        status: skip_status[:status],
                        submission_reason: comment_result[:reason],
                        submission_marker_text: comment_result[:marker_text]
                      }
                    )
                  end
                end
              rescue StandardError => e
                stats[:failed] += 1
                profile.record_event!(
	                  kind: "story_sync_failed",
	                  external_id: "story_sync_failed:#{story_id}:#{Time.current.utc.iso8601(6)}",
	                  occurred_at: Time.current,
	                  metadata: { source: "home_story_carousel", story_id: story_id, story_ref: ref, story_url: story_url, error_class: e.class.name, error_message: e.message }
	                )
	              end

              moved = click_next_story_in_carousel!(driver: driver, current_ref: ref)
              unless moved
                exit_reason = "next_navigation_failed"
                break
              end
            end

            if stats[:stories_visited].zero?
              stats[:failed] += 1
              capture_task_html(
                driver: driver,
                task_name: "home_story_sync_no_progress",
                status: "error",
                meta: {
                  reason: "loop_exited_without_story_processing",
                  current_url: driver.current_url.to_s,
                  page_title: driver.title.to_s,
                  stats: stats
                }
              )
              account_profile.record_event!(
                kind: "story_sync_failed",
                external_id: "story_sync_failed:no_progress:#{Time.current.utc.iso8601(6)}",
                occurred_at: Time.current,
                metadata: {
                  source: "home_story_carousel",
                  reason: "loop_exited_without_story_processing",
                  current_url: driver.current_url.to_s,
                  page_title: driver.title.to_s
                }
              )
            end
            capture_task_html(
              driver: driver,
              task_name: "home_story_sync_end_state",
              status: "ok",
              meta: {
                reason: exit_reason,
                story_limit: limit,
                stats: stats,
                current_url: driver.current_url.to_s
              }
            )
            account_profile.record_event!(
              kind: "story_sync_completed",
              external_id: "story_sync_completed:home_carousel:#{Time.current.utc.iso8601(6)}",
              occurred_at: Time.current,
              metadata: {
                source: "home_story_carousel",
                story_limit: limit,
                auto_reply_only: tagged_only,
                stats: stats,
                end_reason: exit_reason
              }
            )

            stats
          end
        end
      end
    end

    def send_messages!(usernames:, message_text:)
      raise "Message cannot be blank" if message_text.to_s.strip.blank?

      with_recoverable_session(label: "send_messages") do
        sent = 0
        failed = 0
        fallback_usernames = []

        usernames.each do |username|
          begin
            profile = find_profile_for_interaction(username: username)
            if dm_interaction_retry_pending?(profile)
              failed += 1
              next
            end

            api_result = send_direct_message_via_api!(username: username, message_text: message_text)
            if api_result[:sent]
              mark_profile_dm_state!(
                profile: profile,
                state: "messageable",
                reason: "api_text_sent",
                retry_after_at: nil
              )
              sent += 1
            else
              apply_dm_state_from_send_result(profile: profile, result: api_result)
              fallback_usernames << username
            end
          rescue StandardError => e
            raise if disconnected_session_error?(e)

            fallback_usernames << username
          end
        end

        if fallback_usernames.any?
          with_authenticated_driver do |driver|
            fallback_usernames.each do |username|
              begin
                next unless open_dm(driver, username)

                send_text_message_from_driver!(driver, message_text)
                profile = find_profile_for_interaction(username: username)
                mark_profile_dm_state!(
                  profile: profile,
                  state: "messageable",
                  reason: "ui_fallback_sent",
                  retry_after_at: nil
                )
                sent += 1
                sleep(0.8)
              rescue StandardError => e
                raise if disconnected_session_error?(e)

                failed += 1
              end
            end
          end
        end

        # API failures that did not send and were not recovered by UI fallback count as failed.
        unresolved = usernames.length - sent - failed
        failed += unresolved if unresolved.positive?

        {
          attempted: usernames.length,
          sent: sent,
          failed: failed
        }
      end
    end

    def send_message_to_user!(username:, message_text:)
      with_recoverable_session(label: "send_message") do
        profile = find_profile_for_interaction(username: username)
        if dm_interaction_retry_pending?(profile)
          retry_after = profile&.dm_interaction_retry_after_at
          stamp = retry_after&.utc&.iso8601
          raise "DM retry pending for #{username}#{stamp.present? ? " until #{stamp}" : ""}"
        end

        api_result = send_direct_message_via_api!(username: username, message_text: message_text)
        if api_result[:sent]
          mark_profile_dm_state!(
            profile: profile,
            state: "messageable",
            reason: "api_text_sent",
            retry_after_at: nil
          )
          return true
        end

        apply_dm_state_from_send_result(profile: profile, result: api_result)

        with_authenticated_driver do |driver|
          raise "Message cannot be blank" if message_text.to_s.strip.blank?
          raise "Username cannot be blank" if username.to_s.strip.blank?

          ok =
            with_task_capture(driver: driver, task_name: "dm_open", meta: { username: username }) do
              open_dm(driver, username)
            end
          raise "Unable to open DM for #{username}" unless ok

          with_task_capture(
            driver: driver,
            task_name: "dm_send_text",
            meta: {
              username: username,
              message_preview: message_text.to_s.strip.byteslice(0, 80),
              api_fallback_reason: api_result[:reason].to_s
            }
          ) do
            send_text_message_from_driver!(driver, message_text.to_s, expected_username: username)
          end
          mark_profile_dm_state!(
            profile: profile,
            state: "messageable",
            reason: "ui_fallback_sent",
            retry_after_at: nil
          )
          sleep(0.6)
          true
        end
      end
    end

    # API-first DM text send. Falls back to UI from caller when this returns sent=false.
    #
    # Request pattern mirrors story reply thread usage:
    # - resolve user_id from username
    # - create/get direct thread id
    # - POST /api/v1/direct_v2/threads/broadcast/text/
    def send_direct_message_via_api!(username:, message_text:)
      text = message_text.to_s.strip
      return { sent: false, method: "api", reason: "blank_message_text" } if text.blank?

      uname = normalize_username(username)
      return { sent: false, method: "api", reason: "blank_username" } if uname.blank?

      user_id = story_user_id_for(username: uname)
      return { sent: false, method: "api", reason: "missing_user_id" } if user_id.blank?

      thread_id = direct_thread_id_for_user(user_id: user_id)
      return { sent: false, method: "api", reason: "missing_thread_id" } if thread_id.blank?

      body = ig_api_post_form_json(
        path: "/api/v1/direct_v2/threads/broadcast/text/",
        referer: "#{INSTAGRAM_BASE_URL}/direct/t/#{thread_id}/",
        form: {
          action: "send_item",
          client_context: story_api_client_context,
          thread_id: thread_id,
          text: text
        }
      )
      return { sent: false, method: "api", reason: "empty_api_response" } unless body.is_a?(Hash)

      status = body["status"].to_s
      if status == "ok"
        return {
          sent: true,
          method: "api",
          reason: "text_sent",
          api_status: status,
          api_thread_id: body.dig("payload", "thread_id").to_s.presence || thread_id,
          api_item_id: body.dig("payload", "item_id").to_s.presence
        }
      end

      {
        sent: false,
        method: "api",
        reason: body["message"].to_s.presence || body.dig("payload", "message").to_s.presence || body["error_type"].to_s.presence || "api_status_#{status.presence || 'unknown'}",
        api_status: status.presence || "unknown",
        api_http_status: body["_http_status"],
        api_error_code: body.dig("payload", "error_code").to_s.presence || body["error_code"].to_s.presence
      }
    rescue StandardError => e
      { sent: false, method: "api", reason: "api_exception:#{e.class.name}" }
    end

    def post_comment_to_media!(media_id:, shortcode:, comment_text:)
      text = comment_text.to_s.strip
      raise "Comment cannot be blank" if text.blank?
      raise "Media id is required to post comment" if media_id.to_s.strip.blank?
      raise "Post shortcode is required" if shortcode.to_s.strip.blank?

      with_recoverable_session(label: "post_comment") do
        with_authenticated_driver do |driver|
          with_task_capture(
            driver: driver,
            task_name: "post_comment_open_post",
            meta: { shortcode: shortcode.to_s, media_id: media_id.to_s }
          ) do
            driver.navigate.to("#{INSTAGRAM_BASE_URL}/p/#{shortcode}/")
            wait_for(driver, css: "body", timeout: 12)
            dismiss_common_overlays!(driver)
          end

          payload = post_comment_via_api_from_browser_context(
            driver: driver,
            media_id: media_id.to_s.strip,
            comment_text: text
          )

          parsed = parse_comment_api_payload(payload)
          return parsed[:body].merge("method" => "api", "media_id" => media_id.to_s) if parsed[:ok]

          # IG has started rejecting this endpoint on some sessions/builds with 403.
          # Fallback to visible UI interaction to preserve "Forward Post" behavior.
          capture_task_html(
            driver: driver,
            task_name: "post_comment_api_failed_fallback_ui",
            status: "error",
            meta: {
              shortcode: shortcode.to_s,
              media_id: media_id.to_s,
              api_status: parsed[:status],
              api_error: parsed[:error_message],
              api_response_preview: parsed[:response_preview]
            }
          )

          posted = comment_on_post_via_ui!(driver: driver, shortcode: shortcode.to_s, comment_text: text)
          raise "Instagram comment API returned HTTP #{parsed[:status]}; UI fallback also failed" unless posted

          {
            "status" => "ok",
            "method" => "ui_fallback",
            "api_status" => parsed[:status],
            "api_error" => parsed[:error_message],
            "media_id" => media_id.to_s
          }
        end
      end
    end

    def fetch_profile_details!(username:)
      with_recoverable_session(label: "fetch_profile_details") do
        with_authenticated_driver do |driver|
          fetch_profile_details_from_driver(driver, username: username)
        end
      end
    end

    def fetch_profile_details_and_verify_messageability!(username:)
      with_recoverable_session(label: "fetch_profile_details_and_verify_messageability") do
        with_authenticated_driver do |driver|
          details = fetch_profile_details_from_driver(driver, username: username)
          eligibility = verify_messageability_from_api(username: username)
          if eligibility[:can_message].nil?
            eligibility = verify_messageability_from_driver(driver, username: username)
          end
          details.merge(eligibility)
        end
      end
    end

    def verify_messageability!(username:)
      with_recoverable_session(label: "verify_messageability") do
        result = verify_messageability_from_api(username: username)
        return result if !result.is_a?(Hash) || !result[:can_message].nil?

        with_authenticated_driver do |driver|
          verify_messageability_from_driver(driver, username: username)
        end
      end
    end

    def fetch_profile_analysis_dataset!(username:, posts_limit: nil, comments_limit: 8)
      username = normalize_username(username)
      raise "Username cannot be blank" if username.blank?

      details = fetch_profile_details!(username: username)
      web_info = fetch_web_profile_info(username)
      user = web_info.is_a?(Hash) ? web_info.dig("data", "user") : nil
      user_id = user.is_a?(Hash) ? user["id"].to_s.strip.presence : nil
      user_id ||= details[:ig_user_id].to_s.strip.presence if details.is_a?(Hash)

      feed_result = fetch_profile_feed_items_for_analysis(
        username: username,
        user_id: user_id,
        posts_limit: posts_limit
      )
      items = Array(feed_result[:items])

      posts = items.filter_map do |item|
        extract_post_for_analysis(item, comments_limit: comments_limit, referer_username: username)
      end
      enrich_missing_post_comments_via_browser!(
        username: username,
        posts: posts,
        comments_limit: comments_limit
      )

      {
        profile: details,
        posts: posts,
        fetched_at: Time.current,
        feed_fetch: feed_result.except(:items)
      }
    end

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
        count = remaining.present? ? [remaining, PROFILE_FEED_PAGE_SIZE].min : PROFILE_FEED_PAGE_SIZE
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

    def fetch_profile_story_dataset!(username:, stories_limit: 20)
      username = normalize_username(username)
      raise "Username cannot be blank" if username.blank?

      details = fetch_profile_details!(username: username)
      web_info = fetch_web_profile_info(username)
      user = web_info.is_a?(Hash) ? web_info.dig("data", "user") : nil
      user_id = user.is_a?(Hash) ? user["id"].to_s.strip : ""

      reel = user_id.present? ? fetch_story_reel(user_id: user_id, referer_username: username) : nil
      raw_items =
        if reel.is_a?(Hash)
          Array(reel["items"])
        else
          []
        end

      stories = raw_items.first(stories_limit.to_i.clamp(1, 30)).filter_map do |item|
        extract_story_item(item, username: username, reel_owner_id: user_id)
      end

      {
        profile: details,
        user_id: user_id.presence,
        stories: stories,
        fetched_at: Time.current
      }
    end

    private

    def post_comment_via_api_from_browser_context(driver:, media_id:, comment_text:)
      driver.execute_async_script(
        <<~JS,
          const mediaId = arguments[0];
          const comment = arguments[1];
          const done = arguments[arguments.length - 1];

          const body = new URLSearchParams();
          body.set("comment_text", comment);

          const readCookie = (name) => {
            try {
              const cookie = document.cookie || "";
              const parts = cookie.split(";").map((v) => v.trim());
              const hit = parts.find((v) => v.startsWith(name + "="));
              if (!hit) return "";
              return decodeURIComponent(hit.slice(name.length + 1));
            } catch (e) {
              return "";
            }
          };

          const csrf = readCookie("csrftoken");
          const appId =
            document.querySelector("meta[property='al:ios:app_store_id']")?.getAttribute("content") ||
            "936619743392459";
          const rolloutHash =
            window._sharedData?.rollout_hash ||
            window.__initialData?.rollout_hash ||
            "";

          fetch(`/api/v1/web/comments/${mediaId}/add/`, {
            method: "POST",
            credentials: "include",
            headers: {
              "Accept": "application/json, text/plain, */*",
              "Content-Type": "application/x-www-form-urlencoded; charset=UTF-8",
              "X-Requested-With": "XMLHttpRequest",
              "X-CSRFToken": csrf,
              "X-IG-App-ID": appId,
              "X-Instagram-AJAX": rolloutHash,
              "Referer": window.location.href
            },
            body: body.toString()
          })
          .then(async (resp) => {
            const textBody = await resp.text();
            done({
              ok: resp.ok,
              status: resp.status,
              content_type: resp.headers.get("content-type") || "",
              body: textBody
            });
          })
          .catch((err) => {
            done({
              ok: false,
              status: 0,
              content_type: "",
              body: "",
              error: String(err)
            });
          });
        JS
        media_id.to_s.strip,
        comment_text.to_s
      )
    end

    def parse_comment_api_payload(payload)
      unless payload.is_a?(Hash)
        return {
          ok: false,
          status: nil,
          error_message: "Unexpected response while posting comment",
          response_preview: payload.to_s.byteslice(0, 500)
        }
      end

      status = payload["status"]
      body_raw = payload["body"].to_s
      ctype = payload["content_type"].to_s
      preview = body_raw.byteslice(0, 900)
      return { ok: false, status: status, error_message: payload["error"].to_s.presence || "Request failed", response_preview: preview } unless payload["ok"] == true

      return { ok: false, status: status, error_message: "Instagram comment API returned non-JSON response", response_preview: preview } unless ctype.include?("json")

      body = JSON.parse(body_raw) rescue {}
      body_status = body["status"].to_s
      return { ok: false, status: status, error_message: "Instagram comment API returned status=#{body_status.presence || 'unknown'}", response_preview: preview } unless body_status == "ok"

      { ok: true, status: status, body: body, response_preview: preview }
    end

    def with_authenticated_driver
      if @account.cookies.blank?
        raise AuthenticationRequiredError, "No stored cookies. Use manual login or import cookies first."
      end

      with_driver do |driver|
        apply_session_bundle!(driver)
        driver.navigate.to("#{INSTAGRAM_BASE_URL}/")
        ensure_authenticated!(driver)

        result = yield(driver)
        refresh_account_snapshot!(driver)
        result
      end
    end

    def with_driver(headless: env_headless?)
      driver = Selenium::WebDriver.for(:chrome, options: chrome_options(headless: headless))
      yield(driver)
    ensure
      driver&.quit
    end

    def chrome_options(headless:)
      options = Selenium::WebDriver::Chrome::Options.new
      options.add_argument("--window-size=1400,1200")
      options.add_argument("--disable-notifications")
      options.add_argument("--disable-dev-shm-usage")
      options.add_argument("--disable-gpu")
      options.add_argument("--remote-debugging-pipe")
      options.add_argument("--no-sandbox")
      options.add_argument("--headless=new") if headless

      # Enable browser console + performance logs for debugging (captured into our task artifacts when available).
      # Note: ChromeDriver support varies by version; we guard reads in `capture_task_html`.
      options.add_option("goog:loggingPrefs", { browser: "ALL", performance: "ALL" })

      # Allow an opt-in bypass for corp TLS interception setups where the Selenium Chrome instance does not
      # trust the proxy CA. Keep this OFF by default.
      if ActiveModel::Type::Boolean.new.cast(ENV["INSTAGRAM_CHROME_IGNORE_CERT_ERRORS"])
        options.add_argument("--ignore-certificate-errors")
        options.add_argument("--ignore-ssl-errors=yes")
      end

      # Sticky sessions in headless are more reliable when we keep a consistent UA.
      if @account.user_agent.present?
        options.add_argument("--user-agent=#{@account.user_agent}")
      end

      options
    end

    def env_headless?
      Rails.application.config.x.instagram.headless == true
    end

    def wait_for_manual_login!(driver:, timeout_seconds:)
      timeout_at = Time.now + timeout_seconds

      loop do
        cookie_names = driver.manage.all_cookies.map { |c| c[:name] }
        return if cookie_names.include?("sessionid")

        raise "Timed out waiting for manual Instagram login" if Time.now > timeout_at

        sleep(1)
      end
    end

    def persist_cookies!(driver)
      @account.cookies = driver.manage.all_cookies.map { |cookie| cookie.transform_keys(&:to_s) }
    end

    def persist_session_bundle!(driver)
      # Capture after successful 2FA and redirect to authenticated session.
      @account.user_agent = safe_driver_value(driver) { driver.execute_script("return navigator.userAgent") }

      persist_cookies!(driver)
      @account.local_storage = read_web_storage(driver, "localStorage")
      @account.session_storage = read_web_storage(driver, "sessionStorage")
      ig_app_id = detect_ig_app_id(driver)

      @account.auth_snapshot = {
        captured_at: Time.current.utc.iso8601(3),
        current_url: safe_driver_value(driver) { driver.current_url },
        page_title: safe_driver_value(driver) { driver.title },
        ig_app_id: ig_app_id,
        sessionid_present: @account.cookies.any? { |c| c["name"].to_s == "sessionid" && c["value"].to_s.present? },
        cookie_names: @account.cookies.map { |c| c["name"] }.compact.uniq.sort,
        local_storage_keys: @account.local_storage.map { |e| e["key"] }.compact.uniq.sort,
        session_storage_keys: @account.session_storage.map { |e| e["key"] }.compact.uniq.sort
      }
    end

    def refresh_account_snapshot!(driver)
      persist_session_bundle!(driver)
      @account.save! if @account.changed?
    rescue StandardError => e
      Rails.logger.warn("Instagram snapshot refresh skipped: #{e.class}: #{e.message}")
    end

    def apply_session_bundle!(driver)
      # Need a base navigation first so Chrome is on the correct domain for cookies + storage.
      driver.navigate.to(INSTAGRAM_BASE_URL)

      apply_cookies!(driver)
      write_web_storage(driver, "localStorage", @account.local_storage)
      write_web_storage(driver, "sessionStorage", @account.session_storage)
    end

    def detect_ig_app_id(driver)
      script = <<~JS
        const candidates = []
        const push = (value) => {
          if (value === null || typeof value === "undefined") return
          const text = String(value)
          const match = text.match(/\\d{8,}/)
          if (match) candidates.push(match[0])
        }

        try { push(document.documentElement?.getAttribute("data-app-id")) } catch (e) {}
        try { push(window._sharedData?.config?.app_id) } catch (e) {}
        try { push(window.__initialData?.config?.app_id) } catch (e) {}
        try { push(window.localStorage?.getItem("ig_app_id")) } catch (e) {}
        try { push(window.localStorage?.getItem("app_id")) } catch (e) {}
        try { push(window.sessionStorage?.getItem("ig_app_id")) } catch (e) {}

        return candidates[0] || null
      JS

      detected = safe_driver_value(driver) { driver.execute_script(script) }.to_s.strip
      return detected if detected.present?

      @account.auth_snapshot.dig("ig_app_id").to_s.presence || "936619743392459"
    rescue StandardError
      @account.auth_snapshot.dig("ig_app_id").to_s.presence || "936619743392459"
    end

    def apply_cookies!(driver)
      driver.navigate.to(INSTAGRAM_BASE_URL)

      @account.cookies.each do |cookie|
        next if cookie["name"].blank? || cookie["value"].blank?

        sanitized_cookie = {
          name: cookie["name"],
          value: cookie["value"],
          path: cookie["path"] || "/",
          secure: bool(cookie["secure"]),
          http_only: bool(cookie["httpOnly"])
        }

        sanitized_cookie[:domain] = cookie["domain"] if cookie["domain"].present?
        sanitized_cookie[:same_site] = normalize_same_site(cookie["sameSite"])

        if cookie["expiry"].present?
          sanitized_cookie[:expires] = cookie["expiry"].to_i
        elsif cookie["expires"].present?
          sanitized_cookie[:expires] = cookie["expires"].to_i
        end

        driver.manage.add_cookie(sanitized_cookie)
      rescue Selenium::WebDriver::Error::UnableToSetCookieError
        # Retry without domain/same_site for host-only or incompatible cookie attributes.
        fallback_cookie = sanitized_cookie.except(:domain, :same_site)
        driver.manage.add_cookie(fallback_cookie)
      rescue Selenium::WebDriver::Error::InvalidCookieDomainError
        next
      rescue Selenium::WebDriver::Error::UnableToSetCookieError
        next
      end
    end

    def ensure_authenticated!(driver)
      with_task_capture(driver: driver, task_name: "auth_validate_session") do
        wait_for(driver, css: "body", timeout: 10)

        # Validate against inbox route because "/" can be public and still unauthenticated.
        driver.navigate.to("#{INSTAGRAM_BASE_URL}/direct/inbox/")
        wait_for(driver, css: "body", timeout: 10)

        if driver.current_url.include?("/accounts/login") || logged_out_page?(driver)
          raise AuthenticationRequiredError, "Stored cookies are not authenticated. Re-run Manual Browser Login or import fresh cookies."
        end
      end
    end

    def collect_conversation_users(driver)
      meta = { extraction: "inbox_page_source_verify_contact_row_exists" }

      with_task_capture(driver: driver, task_name: "sync_collect_conversation_users", meta: meta) do
        api_users = fetch_conversation_users_via_api(limit: 120)
        if api_users.present?
          meta[:source] = "api_direct_inbox"
          meta[:unique_usernames] = api_users.length
          return api_users
        end

        meta[:source] = "html_fallback"
        users = {}
        driver.navigate.to("#{INSTAGRAM_BASE_URL}/direct/inbox/")
        wait_for(driver, css: "body", timeout: 10)

        # Inbox content is often rendered via large JSON payloads; wait for those to exist.
        Selenium::WebDriver::Wait.new(timeout: 10).until do
          driver.page_source.to_s.include?("verifyContactRowExists") || driver.page_source.to_s.include?("LSVerifyContactRowExists")
        end

        verify_segments_total = 0
        extracted_total = 0

        8.times do
          html = driver.page_source.to_s
          extracted, verify_segments = extract_conversation_users_from_inbox_html(html)
          verify_segments_total += verify_segments
          extracted_total += extracted.length

          extracted.each do |username, attrs|
            users[username] ||= attrs
          end

          # Inbox uses a nested scroller in many builds; try to scroll that first.
          driver.execute_script(<<~JS)
            const candidate =
              document.querySelector("div[role='main']") ||
              document.querySelector("div[role='grid']") ||
              document.scrollingElement ||
              document.documentElement ||
              document.body;
            try { candidate.scrollTop = (candidate.scrollTop || 0) + 750; } catch (e) {}
            try { window.scrollBy(0, 750); } catch (e) {}
          JS
          sleep(0.4)
        end

        meta[:verify_contact_row_segments] = verify_segments_total
        meta[:extracted_usernames_total] = extracted_total
        meta[:unique_usernames] = users.length

        users
      end
    end

    def collect_story_users(driver)
      meta = { extraction: "home_stories_anchors_and_regex" }

      with_task_capture(driver: driver, task_name: "sync_collect_story_users", meta: meta) do
        api_users = fetch_story_users_via_api
        if api_users.present?
          meta[:source] = "api_reels_tray"
          meta[:unique_story_usernames] = api_users.length
          return api_users
        end

        meta[:source] = "html_fallback"
        users = {}
        driver.navigate.to(INSTAGRAM_BASE_URL)
        wait_for(driver, css: "body", timeout: 10)

        dismiss_common_overlays!(driver)

        html = driver.page_source.to_s
        extracted_users = extract_story_users_from_home_html(html)
        meta[:story_prefetch_usernames] = extracted_users.length

        extracted_users.each do |username|
          users[username] ||= { display_name: username }
        end

        # If we didn't get anything from prefetched query payloads, try DOM anchors as a fallback.
        if users.empty?
          begin
            Selenium::WebDriver::Wait.new(timeout: 12).until do
              driver.find_elements(css: "a[href*='/stories/']").any?
            end
          rescue Selenium::WebDriver::Error::TimeoutError
            meta[:story_anchor_wait_timed_out] = true
          end

          story_hrefs = driver.find_elements(css: "a[href*='/stories/']").map { |a| a.attribute("href").to_s }.reject(&:blank?)
          meta[:story_anchor_hrefs] = story_hrefs.length

          story_hrefs.each do |href|
            username = href.split("/stories/").last.to_s.split("/").first.to_s
            username = normalize_username(username)
            next if username.blank?

            users[username] ||= { display_name: username }
          end

          # Fallback: parse the page source for story links even if anchors use different tag/attrs.
          html = driver.page_source.to_s
          story_usernames = html.scan(%r{/stories/([A-Za-z0-9._]{1,30})/}).flatten.map { |u| normalize_username(u) }.reject(&:blank?).uniq
          meta[:story_regex_usernames] = story_usernames.length

          story_usernames.each do |username|
            users[username] ||= { display_name: username }
          end
        else
          meta[:story_anchor_hrefs] = 0
          meta[:story_regex_usernames] = 0
        end

        meta[:unique_story_usernames] = users.length

        users
      end
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
          media_url: h["media_url"].to_s,
          caption: h["caption"],
          metadata: h["metadata"] || {}
        }
      end
    rescue StandardError
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

    def fetch_eligibility(driver, username)
      with_task_capture(driver: driver, task_name: "sync_fetch_eligibility", meta: { username: username }) do
        api_result = verify_messageability_from_api(username: username)
        if api_result.is_a?(Hash) && !api_result[:can_message].nil?
          return {
            can_message: api_result[:can_message],
            restriction_reason: api_result[:restriction_reason],
            source: "api",
            dm_state: api_result[:dm_state],
            dm_reason: api_result[:dm_reason],
            dm_retry_after_at: api_result[:dm_retry_after_at]
          }
        end

        driver.navigate.to("#{INSTAGRAM_BASE_URL}/#{username}/")
        wait_for(driver, css: "body", timeout: 8)

        page = driver.page_source.to_s
        page_down = page.downcase

        # If we hit a generic error page or an interstitial, eligibility is unknown.
        if page_down.include?("something went wrong") ||
           page_down.include?("unexpected error") ||
           page_down.include?("polarishttp500") ||
           page_down.include?("try again later")
          return { can_message: false, restriction_reason: "Unable to verify messaging availability (profile load error)" }
        end

        # "Message" often renders as <div role="button"> on modern IG builds (not only <button>).
        message_cta =
          driver.find_elements(xpath: "//*[self::button or (self::div and @role='button')][normalize-space()='Message']").first ||
          driver.find_elements(xpath: "//*[self::a and @role='link' and normalize-space()='Message']").first

        follow_cta =
          driver.find_elements(xpath: "//*[self::button or (self::div and @role='button')][normalize-space()='Follow']").first ||
          driver.find_elements(xpath: "//*[self::button or (self::div and @role='button')][normalize-space()='Requested']").first

        if message_cta
          { can_message: true, restriction_reason: nil }
        elsif follow_cta
          { can_message: false, restriction_reason: "User is not currently messageable from this account" }
        elsif page_down.include?("private")
          { can_message: false, restriction_reason: "Private or restricted profile" }
        else
          { can_message: false, restriction_reason: "Unable to verify messaging availability" }
        end
      end
    end

    def fetch_profile_details_from_driver(driver, username:)
      username = normalize_username(username)
      raise "Username cannot be blank" if username.blank?

      with_task_capture(driver: driver, task_name: "profile_fetch_details", meta: { username: username }) do
        api_details = fetch_profile_details_via_api(username)
        return api_details if api_details.present?

        driver.navigate.to("#{INSTAGRAM_BASE_URL}/#{username}/")
        wait_for(driver, css: "body", timeout: 10)
        dismiss_common_overlays!(driver)

        html = driver.page_source.to_s

        display_name = nil
        if (og = html.match(/property=\"og:title\" content=\"([^\"]+)\"/))
          og_title = CGI.unescapeHTML(og[1].to_s)
          # Examples: "Name (@username) • Instagram photos and videos"
          if (m = og_title.match(/\A(.+?)\s*\(@#{Regexp.escape(username)}\)\b/))
            display_name = m[1].to_s.strip
          end
        end

        pic = nil
        if (img = html.match(/property=\"og:image\" content=\"([^\"]+)\"/))
          pic = CGI.unescapeHTML(img[1].to_s).strip
        end

        web_info = fetch_web_profile_info(username)
        web_user = web_info.is_a?(Hash) ? web_info.dig("data", "user") : nil
        ig_user_id = web_user.is_a?(Hash) ? web_user["id"].to_s.strip.presence : nil
        bio = web_user.is_a?(Hash) ? web_user["biography"].to_s.presence : nil
        full_name = web_user.is_a?(Hash) ? web_user["full_name"].to_s.strip.presence : nil
        followers_count = web_user.is_a?(Hash) ? normalize_count(web_user["follower_count"]) : nil
        followers_count ||= extract_profile_follow_counts(html)&.dig(:followers)
        category_name = web_user.is_a?(Hash) ? web_user["category_name"].to_s.strip.presence : nil
        is_business_account = web_user.is_a?(Hash) ? ActiveModel::Type::Boolean.new.cast(web_user["is_business_account"]) : nil

        display_name ||= full_name

        post = extract_latest_post_from_profile_dom(driver)
        post = extract_latest_post_from_profile_html(html) if post[:taken_at].blank? && post[:shortcode].blank?
        post = extract_latest_post_from_profile_http(username) if post[:taken_at].blank? && post[:shortcode].blank?

        {
          username: username,
          display_name: display_name,
          profile_pic_url: pic,
          ig_user_id: ig_user_id,
          bio: bio,
          followers_count: followers_count,
          category_name: category_name,
          is_business_account: is_business_account,
          last_post_at: post[:taken_at],
          latest_post_shortcode: post[:shortcode]
        }
      end
    end

    def extract_latest_post_from_profile_html(html)
      return { taken_at: nil, shortcode: nil } if html.blank?

      # Prefer restricting our search to a window around the timeline media payload to avoid
      # grabbing unrelated timestamps elsewhere in the page.
      idx = html.index("edge_owner_to_timeline_media") || html.index("timeline_media")
      window = idx ? (html.byteslice(idx, 250_000) || "") : html

      taken_at = nil
      shortcode = nil

      if (m = window.match(/\"taken_at_timestamp\":(\d{9,})/))
        ts = m[1].to_i
        taken_at = Time.at(ts).utc rescue nil
      end

      if (m = window.match(/\"shortcode\":\"([A-Za-z0-9_-]{5,})\"/))
        shortcode = m[1].to_s
      end

      { taken_at: taken_at, shortcode: shortcode }
    rescue StandardError
      { taken_at: nil, shortcode: nil }
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

    def extract_latest_post_from_profile_http(username)
      username = normalize_username(username)
      return { taken_at: nil, shortcode: nil } if username.blank?

      data = fetch_web_profile_info(username)
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

      feed = fetch_user_feed(user_id: user_id, referer_username: username, count: 6)
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

    def fetch_web_profile_info(username)
      # Unofficial endpoint used by the Instagram web app; requires authenticated cookies.
      uri = URI.parse("#{INSTAGRAM_BASE_URL}/api/v1/users/web_profile_info/?username=#{username}")

      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = (uri.scheme == "https")
      http.open_timeout = 10
      http.read_timeout = 20

      req = Net::HTTP::Get.new(uri.request_uri)
      req["User-Agent"] = @account.user_agent.presence || "Mozilla/5.0"
      req["Accept"] = "application/json, text/plain, */*"
      req["X-Requested-With"] = "XMLHttpRequest"
      req["X-IG-App-ID"] = (@account.auth_snapshot.dig("ig_app_id").presence || "936619743392459")
      req["Referer"] = "#{INSTAGRAM_BASE_URL}/#{username}/"

      csrf = @account.cookies.find { |c| c["name"].to_s == "csrftoken" }&.dig("value").to_s
      req["X-CSRFToken"] = csrf if csrf.present?
      req["Cookie"] = cookie_header_for(@account.cookies)

      res = http.request(req)
      return nil unless res.is_a?(Net::HTTPSuccess)

      JSON.parse(res.body.to_s)
    rescue StandardError
      nil
    end

    def fetch_user_feed(user_id:, referer_username:, count:, max_id: nil)
      q = [ "count=#{count.to_i.clamp(1, 30)}" ]
      q << "max_id=#{CGI.escape(max_id.to_s)}" if max_id.present?
      uri = URI.parse("#{INSTAGRAM_BASE_URL}/api/v1/feed/user/#{user_id}/?#{q.join('&')}")

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

      JSON.parse(res.body.to_s)
    rescue StandardError
      nil
    end

    def fetch_profile_details_via_api(username)
      uname = normalize_username(username)
      return nil if uname.blank?

      web_info = fetch_web_profile_info(uname)
      user = web_info.is_a?(Hash) ? web_info.dig("data", "user") : nil
      return nil unless user.is_a?(Hash)

      latest = extract_latest_post_from_profile_http(uname)

      {
        username: uname,
        display_name: user["full_name"].to_s.strip.presence,
        profile_pic_url: CGI.unescapeHTML(user["profile_pic_url_hd"].to_s).strip.presence || CGI.unescapeHTML(user["profile_pic_url"].to_s).strip.presence,
        ig_user_id: user["id"].to_s.strip.presence,
        bio: user["biography"].to_s.presence,
        followers_count: normalize_count(user["follower_count"]),
        category_name: user["category_name"].to_s.strip.presence,
        is_business_account: ActiveModel::Type::Boolean.new.cast(user["is_business_account"]),
        last_post_at: latest[:taken_at],
        latest_post_shortcode: latest[:shortcode]
      }
    rescue StandardError
      nil
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

    def fetch_conversation_users_via_api(limit: 120)
      users = {}
      cursor = nil
      remaining = limit.to_i.clamp(1, 400)
      safety = 0

      loop do
        safety += 1
        break if safety > 12
        break if remaining <= 0

        count = [ remaining, 50 ].min
        q = [ "limit=#{count}", "visual_message_return_type=unseen" ]
        q << "cursor=#{CGI.escape(cursor)}" if cursor.present?
        path = "/api/v1/direct_v2/inbox/?#{q.join('&')}"
        body = ig_api_get_json(path: path, referer: "#{INSTAGRAM_BASE_URL}/direct/inbox/")
        break unless body.is_a?(Hash)

        inbox = body["inbox"].is_a?(Hash) ? body["inbox"] : {}
        threads = Array(inbox["threads"])
        break if threads.empty?

        threads.each do |thread|
          next unless thread.is_a?(Hash)
          Array(thread["thread_users"]).each do |u|
            next unless u.is_a?(Hash)
            username = normalize_username(u["username"])
            next if username.blank?

            users[username] ||= {
              display_name: u["full_name"].to_s.strip.presence || username,
              profile_pic_url: CGI.unescapeHTML(u["profile_pic_url"].to_s).strip.presence
            }
          end
        end

        remaining -= threads.length
        cursor = inbox["oldest_cursor"].to_s.strip.presence
        break if cursor.blank?
      end

      users
    rescue StandardError
      {}
    end

    def fetch_story_users_via_api
      body = ig_api_get_json(path: "/api/v1/feed/reels_tray/", referer: INSTAGRAM_BASE_URL)
      return {} unless body.is_a?(Hash)

      tray_items =
        if body["tray"].is_a?(Array)
          body["tray"]
        elsif body["tray"].is_a?(Hash)
          Array(body.dig("tray", "items"))
        else
          []
        end

      users = {}
      tray_items.each do |item|
        next unless item.is_a?(Hash)
        user = item["user"].is_a?(Hash) ? item["user"] : item
        username = normalize_username(user["username"])
        next if username.blank?

        users[username] ||= {
          display_name: user["full_name"].to_s.strip.presence || username,
          profile_pic_url: CGI.unescapeHTML(user["profile_pic_url"].to_s).strip.presence
        }
      end

      users
    rescue StandardError
      {}
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

      {
        shortcode: shortcode,
        post_kind: post_kind,
        author_username: normalize_username(item.dig("user", "username").to_s),
        media_url: (video_url.presence || image_url).to_s,
        caption: item.dig("caption", "text").to_s.presence,
        metadata: {
          source: "api_timeline",
          media_id: (item["pk"] || item["id"]).to_s.presence,
          media_type: media_type,
          media_url_image: image_url.to_s.presence,
          media_url_video: video_url.to_s.presence,
          product_type: product_type,
          natural_width: width,
          natural_height: height
        }
      }
    rescue StandardError
      nil
    end

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

    # API-only story media resolution:
    # 1) /api/v1/users/web_profile_info?username=...
    # 2) /api/v1/feed/reels_media/?reel_ids=<user_id>
    # Never falls back to DOM media scraping.
    def resolve_story_media_for_current_context(driver:, username:, story_id:, fallback_story_key:, cache: nil)
      uname = normalize_username(username)
      sid = story_id.to_s.strip
      sid = "" if sid.casecmp("unknown").zero?

      api_story = resolve_story_item_via_api(username: uname, story_id: sid, cache: cache)
      if api_story.is_a?(Hash)
        url = api_story[:media_url].to_s
        if url.present?
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

      Ops::StructuredLogger.warn(
        event: "instagram.story_media.api_unresolved",
        payload: {
          username: uname,
          story_id: sid.presence || fallback_story_key.to_s,
          source: "api_only_resolution"
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
      image_url = CGI.unescapeHTML(image_candidate&.dig("url").to_s).strip.presence
      video_url = CGI.unescapeHTML(video_candidate&.dig("url").to_s).strip.presence
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

    def parse_unix_time(value)
      return nil if value.blank?
      Time.at(value.to_i).utc
    rescue StandardError
      nil
    end

    def cookie_header_for(cookies)
      Array(cookies).map do |c|
        name = c["name"].to_s
        value = c["value"].to_s
        next if name.blank? || value.blank?
        "#{name}=#{value}"
      end.compact.join("; ")
    end

    def verify_messageability_from_api(username:)
      uname = normalize_username(username)
      return { can_message: nil, restriction_reason: "Username is blank", source: "api" } if uname.blank?

      user_id = story_user_id_for(username: uname)
      if user_id.blank?
        return {
          can_message: false,
          restriction_reason: "Unable to resolve user id via API",
          source: "api",
          dm_state: "unknown",
          dm_reason: "missing_user_id",
          dm_retry_after_at: Time.current + 6.hours
        }
      end

      thread_result = create_direct_thread_for_user(user_id: user_id, use_cache: false)
      thread_id = thread_result[:thread_id].to_s
      return { can_message: true, restriction_reason: nil, source: "api", dm_state: "messageable", dm_reason: "thread_created", dm_retry_after_at: nil } if thread_id.present?

      reason = thread_result[:reason].to_s.presence || "missing_thread_id"
      retry_after =
        if thread_result[:api_http_status].to_i == 403
          Time.current + STORY_INTERACTION_RETRY_DAYS.days
        else
          Time.current + 12.hours
        end

      {
        can_message: false,
        restriction_reason: "DM unavailable via API (#{reason})",
        source: "api",
        dm_state: "unavailable",
        dm_reason: reason,
        dm_retry_after_at: retry_after,
        api_status: thread_result[:api_status],
        api_http_status: thread_result[:api_http_status],
        api_error_code: thread_result[:api_error_code]
      }
    rescue StandardError => e
      {
        can_message: nil,
        restriction_reason: "Unable to verify messaging availability (api exception)",
        source: "api",
        dm_state: "unknown",
        dm_reason: "exception:#{e.class.name}",
        dm_retry_after_at: Time.current + 6.hours
      }
    end

    def verify_messageability_from_driver(driver, username:)
      username = normalize_username(username)
      raise "Username cannot be blank" if username.blank?

      with_task_capture(driver: driver, task_name: "profile_verify_messageability", meta: { username: username }) do
        ok = open_dm(driver, username)
        if !ok
          {
            can_message: false,
            restriction_reason: "Unable to open DM thread",
            source: "ui",
            dm_state: "unavailable",
            dm_reason: "unable_to_open_dm_thread",
            dm_retry_after_at: Time.current + 12.hours
          }
        else
          begin
            wait_for_present(driver, css: dm_textbox_css, timeout: 10)
            {
              can_message: true,
              restriction_reason: nil,
              source: "ui",
              dm_state: "messageable",
              dm_reason: "composer_visible",
              dm_retry_after_at: nil
            }
          rescue Selenium::WebDriver::Error::TimeoutError
            {
              can_message: false,
              restriction_reason: "Unable to open message box",
              source: "ui",
              dm_state: "unavailable",
              dm_reason: "message_box_unavailable",
              dm_retry_after_at: Time.current + 12.hours
            }
          end
        end
      end
    end

    def open_dm_from_profile(driver, username)
      driver.navigate.to("#{INSTAGRAM_BASE_URL}/#{username}/")
      wait_for(driver, css: "body", timeout: 10)
      dismiss_common_overlays!(driver)
      human_pause

      # Case-insensitive contains("message") across common clickable elements.
      ci = "translate(normalize-space(.), 'ABCDEFGHIJKLMNOPQRSTUVWXYZ', 'abcdefghijklmnopqrstuvwxyz')"
      message_xpath = "//*[self::button or (self::div and @role='button') or self::a][contains(#{ci}, 'message')]"
      aria_xpath = "//*[@aria-label and contains(translate(@aria-label,'ABCDEFGHIJKLMNOPQRSTUVWXYZ','abcdefghijklmnopqrstuvwxyz'),'message')]"

      # Wait for the CTA to be visible. Profile pages often render in stages; grabbing `.first` can pick a hidden node.
      message_button =
        begin
          wait_for(driver, xpath: message_xpath, timeout: 10)
        rescue Selenium::WebDriver::Error::TimeoutError
          nil
        end
      message_button ||= driver.find_elements(xpath: aria_xpath).find { |el| el.displayed? rescue false }

      return false unless message_button

      click_ok =
        begin
          driver.action.move_to(message_button).click.perform
          true
        rescue StandardError
          js_click(driver, message_button)
        end

      return false unless click_ok
      maybe_capture_filmstrip(driver, label: "dm_open_profile_after_click")

      true
    end

    def open_dm(driver, username)
      username = normalize_username(username)
      return false if username.blank?

      # Strategy 1: profile page CTA
      ok = with_task_capture(driver: driver, task_name: "dm_open_profile", meta: { username: username }) do
        open_dm_from_profile(driver, username)
      end
      if ok
        begin
          wait_for_dm_composer_or_thread!(driver, timeout: 12)
          return true
        rescue Selenium::WebDriver::Error::TimeoutError
          # fall through to next strategy
        end
      end

      # Strategy 2: direct/new flow (SPA-safe)
      ok2 = with_task_capture(driver: driver, task_name: "dm_open_direct_new", meta: { username: username }) do
        open_dm_via_direct_new(driver, username)
      end
      return true if ok2

      # On some IG builds the URL flips to the thread before the composer becomes queryable.
      driver.current_url.to_s.include?("/direct/t/")
    end

    def open_dm_via_direct_new(driver, username)
      driver.navigate.to("#{INSTAGRAM_BASE_URL}/direct/new/")
      wait_for(driver, css: "body", timeout: 12)
      dismiss_common_overlays!(driver)
      human_pause

      # Find a search box for recipients.
      selectors = [
        "input[name='queryBox']",
        "input[placeholder*='Search']",
        "input[aria-label*='Search']",
        "input[type='text']"
      ]

      typed = false
      3.times do |attempt|
        input =
          selectors.lazy.map { |sel| driver.find_elements(css: sel).find(&:displayed?) }.find(&:present?) ||
          selectors.lazy.map { |sel| driver.find_elements(css: sel).first }.find(&:present?)

        break unless input

        begin
          input.click
          # Clear any existing value.
          input.send_keys([:control, "a"])
          input.send_keys(:backspace)
          input.send_keys(username)
          typed = true
          human_pause
          break
        rescue Selenium::WebDriver::Error::StaleElementReferenceError, Selenium::WebDriver::Error::ElementNotInteractableError
          Rails.logger.info("open_dm_via_direct_new retry typing (attempt #{attempt + 1}/3)")
          sleep(0.5)
          next
        end
      end

      return false unless typed
      capture_task_html(driver: driver, task_name: "dm_open_direct_new_after_type", status: "ok", meta: { username: username })

      # Wait for the username to appear in results and click it.
      username_down = username.to_s.downcase
      ci = "translate(normalize-space(.), 'ABCDEFGHIJKLMNOPQRSTUVWXYZ', 'abcdefghijklmnopqrstuvwxyz')"
      row_xpath = "//div[@role='button'][.//*[contains(#{ci}, '#{username_down}')]]"
      row_with_img_xpath = "//div[@role='button'][.//*[contains(#{ci}, '#{username_down}')]]//img/ancestor::div[@role='button'][1]"

      begin
        Selenium::WebDriver::Wait.new(timeout: 12).until do
          driver.find_elements(xpath: row_with_img_xpath).any? ||
            driver.find_elements(xpath: row_xpath).any? ||
            driver.find_elements(xpath: "//*[contains(#{ci}, '#{username_down}')]").any?
        end
      rescue Selenium::WebDriver::Error::TimeoutError
        return false
      end

      candidate =
        driver.find_elements(xpath: row_with_img_xpath).find { |el| el.displayed? rescue false } ||
        driver.find_elements(xpath: row_xpath).find { |el| el.displayed? rescue false } ||
        driver.find_elements(xpath: row_xpath).first ||
        driver.find_elements(xpath: "//*[contains(#{ci}, '#{username_down}')]").find { |el| el.displayed? rescue false } ||
        driver.find_elements(xpath: "//*[contains(#{ci}, '#{username_down}')]").first
      return false unless candidate

      # Click nearest clickable container; otherwise click the text node parent.
      clickable =
        begin
          driver.execute_script(<<~JS, candidate)
            const el = arguments[0];
            // For direct/new, the row itself is usually role=button.
            if (el && el.getAttribute && el.getAttribute("role") === "button") return el;
            const btn = el.closest("button,[role='button']");
            return btn || el;
          JS
        rescue StandardError
          candidate
        end

      begin
        driver.action.move_to(clickable).click.perform
      rescue StandardError
        js_click(driver, clickable)
      end
      human_pause
      capture_task_html(driver: driver, task_name: "dm_open_direct_new_after_pick", status: "ok", meta: { username: username })

      # Click the continuation CTA to open chat ("Next" on some builds, "Chat" on others).
      continue_btn = nil
      begin
        Selenium::WebDriver::Wait.new(timeout: 12).until do
          continue_btn =
            driver.find_elements(xpath: "//*[self::button or (self::div and @role='button')][normalize-space()='Next']").find(&:displayed?) ||
            driver.find_elements(xpath: "//*[self::button or (self::div and @role='button')][normalize-space()='Chat']").find(&:displayed?) ||
            driver.find_elements(xpath: "//*[self::button or (self::div and @role='button')][contains(translate(normalize-space(.),'ABCDEFGHIJKLMNOPQRSTUVWXYZ','abcdefghijklmnopqrstuvwxyz'),'next')]").find(&:displayed?) ||
            driver.find_elements(xpath: "//*[self::button or (self::div and @role='button')][contains(translate(normalize-space(.),'ABCDEFGHIJKLMNOPQRSTUVWXYZ','abcdefghijklmnopqrstuvwxyz'),'chat')]").find(&:displayed?)
          continue_btn.present? && element_enabled?(continue_btn)
        end
      rescue Selenium::WebDriver::Error::TimeoutError
        continue_btn = nil
      end

      # Some UI variants jump directly into the thread immediately after recipient selection.
      return true if driver.current_url.to_s.include?("/direct/t/")
      return false unless continue_btn

      begin
        driver.action.move_to(continue_btn).click.perform
      rescue StandardError
        js_click(driver, continue_btn)
      end
      maybe_capture_filmstrip(driver, label: "dm_open_direct_new_after_next")
      capture_task_html(driver: driver, task_name: "dm_open_direct_new_after_next", status: "ok", meta: { username: username })

      wait_for_dm_composer_or_thread!(driver, timeout: 16)
      true
    rescue Selenium::WebDriver::Error::TimeoutError
      false
    end

    def wait_for_dm_composer_or_thread!(driver, timeout:)
      Selenium::WebDriver::Wait.new(timeout: timeout).until do
        url = driver.current_url.to_s
        # Some failures bounce back to inbox; treat as not-opened.
        next false if url.include?("/direct/inbox")

        url.include?("/direct/t/") || driver.find_elements(css: "div[role='textbox']").any?
      end
    end

    def element_enabled?(el)
      return false unless el
      return false unless (el.displayed? rescue true)

      disabled_attr = (el.attribute("disabled") rescue nil).to_s
      aria_disabled = (el.attribute("aria-disabled") rescue nil).to_s

      disabled_attr.blank? && aria_disabled != "true"
    rescue StandardError
      true
    end

    def human_pause(min_seconds = 0.15, max_seconds = 0.55)
      return if max_seconds.to_f <= 0
      min = min_seconds.to_f
      max = max_seconds.to_f
      d = min + (rand * (max - min))
      sleep(d.clamp(0.0, 2.0))
    end

    def maybe_capture_filmstrip(driver, label:, seconds: 5.0, interval: 0.5)
      return unless ENV["INSTAGRAM_FILMSTRIP"].present?

      root = DEBUG_CAPTURE_DIR.join(Time.current.utc.strftime("%Y%m%d"))
      FileUtils.mkdir_p(root)

      started = Time.current.utc
      deadline = started + seconds.to_f
      frames = []
      i = 0

      while Time.current.utc < deadline
        ts = Time.current.utc.strftime("%Y%m%dT%H%M%S.%LZ")
        safe = label.to_s.downcase.gsub(/[^a-z0-9]+/, "_").gsub(/\A_|_\z/, "")
        path = root.join("#{ts}_filmstrip_#{safe}_#{format('%03d', i)}.png")
        begin
          driver.save_screenshot(path.to_s)
          frames << path.to_s
        rescue StandardError
          # best effort
        end
        i += 1
        sleep(interval.to_f)
      end

      meta = {
        timestamp: Time.current.utc.iso8601(3),
        label: label,
        seconds: seconds,
        interval: interval,
        frames: frames
      }
      File.write(root.join("#{started.strftime('%Y%m%dT%H%M%S.%LZ')}_filmstrip_#{label}.json"), JSON.pretty_generate(meta))
    rescue StandardError
      nil
    end

    def wait_for(driver, css: nil, xpath: nil, timeout: 10)
      wait = Selenium::WebDriver::Wait.new(timeout: timeout)
      wait.until do
        if css
          elements = driver.find_elements(css: css)
          elements.each do |el|
            begin
              return el if el.displayed?
            rescue Selenium::WebDriver::Error::StaleElementReferenceError
              next
            end
          end
          nil
        elsif xpath
          elements = driver.find_elements(xpath: xpath)
          elements.each do |el|
            begin
              return el if el.displayed?
            rescue Selenium::WebDriver::Error::StaleElementReferenceError
              next
            end
          end
          nil
        end
      end
    end

    def wait_for_present(driver, css: nil, xpath: nil, timeout: 10)
      wait = Selenium::WebDriver::Wait.new(timeout: timeout)
      wait.until do
        if css
          driver.find_elements(css: css).any?
        elsif xpath
          driver.find_elements(xpath: xpath).any?
        end
      end
    end

    def dm_textbox_css
      # The DM composer is a contenteditable div (Lexical editor). On some builds there can be multiple
      # role=textbox nodes (hidden + visible), so we prefer the visible contenteditable one.
      "div[role='textbox'][contenteditable='true'], div[role='textbox']"
    end

	    def send_text_message_from_driver!(driver, message_text, expected_username: nil)
	      raise "Message cannot be blank" if message_text.to_s.strip.blank?

      css = dm_textbox_css
      wait_for_present(driver, css: css, timeout: 12)

      box = find_visible_dm_textbox(driver)
      raise Selenium::WebDriver::Error::NoSuchElementError, "No DM textbox found" unless box

      3.times do |attempt|
        begin
          driver.execute_script("arguments[0].scrollIntoView({block: 'center', inline: 'nearest'});", box)
          driver.execute_script("arguments[0].focus();", box)
          driver.execute_script("arguments[0].click();", box)
        rescue StandardError
          # best effort
        end

        begin
          box.click
        rescue Selenium::WebDriver::Error::ElementClickInterceptedError, Selenium::WebDriver::Error::ElementNotInteractableError
          # ignore; we'll try typing via actions as a fallback
        end

        begin
          # Clear any residual draft text (best effort).
          begin
            driver.action.click(box).key_down(:control).send_keys("a").key_up(:control).send_keys(:backspace).perform
          rescue StandardError
            nil
          end

          # Type using actions (more reliable on IG's Lexical composer than direct send_keys on the element).
          driver.action.click(box).send_keys(message_text.to_s).perform

	          typed = read_dm_textbox_text(driver)
	          capture_task_html(
	            driver: driver,
	            task_name: "dm_send_text_after_type",
	            status: "ok",
	            meta: { expected_username: expected_username, message_preview: message_text.to_s.strip.byteslice(0, 80), textbox_text_preview: typed.to_s.byteslice(0, 120) }
	          )

            # Prefer clicking "Send" first. Recent IG builds sometimes clear the composer on Enter even when
            # the message never actually sends (silent failure), so Enter-first can give a false sense of success.
	          clicked_send = click_dm_send_button(driver, textbox: box)
	          capture_task_html(
	            driver: driver,
	            task_name: "dm_send_text_after_send_click",
	            status: "ok",
	            meta: { expected_username: expected_username, message_preview: message_text.to_s.strip.byteslice(0, 80), clicked_send: clicked_send }
	          )

	          # If we could not click the Send button, attempt Enter as a fallback.
	          enter_attempted = false
	          if !(clicked_send.is_a?(Hash) && clicked_send[:clicked])
	            begin
	              box.send_keys(:enter)
	              enter_attempted = true
	            rescue StandardError
	              enter_attempted = false
	            end
	          end

	          after_enter_text = read_dm_textbox_text(driver)
	          capture_task_html(
	            driver: driver,
	            task_name: "dm_send_text_after_enter",
	            status: "ok",
	            meta: {
	              expected_username: expected_username,
	              message_preview: message_text.to_s.strip.byteslice(0, 80),
	              enter_attempted: enter_attempted,
	              textbox_text_preview: after_enter_text.to_s.byteslice(0, 120),
	              send_button_clicked: (clicked_send.is_a?(Hash) ? clicked_send[:clicked] : nil),
	              send_button_reason: (clicked_send.is_a?(Hash) ? clicked_send[:reason] : nil)
	            }
	          )

	          sent = (clicked_send.is_a?(Hash) ? clicked_send[:clicked] : !!clicked_send) || enter_attempted

	          unless sent
	            # Last resort.
	            driver.action.send_keys(:enter).perform
	          end
          break
        rescue Selenium::WebDriver::Error::StaleElementReferenceError
          sleep(0.4)
          box = find_visible_dm_textbox(driver)
          next
	        rescue Selenium::WebDriver::Error::ElementNotInteractableError, Selenium::WebDriver::Error::InvalidElementStateError
	          # Fallback: send keys to the active element (Instagram's Lexical editor usually focuses it).
	          driver.action.send_keys(message_text.to_s).perform
	          tb = find_visible_dm_textbox(driver)
	          click_dm_send_button(driver, textbox: tb).to_h[:clicked] || driver.action.send_keys(:enter).perform
	          break
	        rescue StandardError
	          raise if attempt >= 2
	          sleep(0.6)
	          next
        end
      end

      verify = verify_dm_send(driver, message_text.to_s, expected_username: expected_username)
      return true if verify[:ok]
      if verify[:reason].to_s.start_with?("websocket_tls_error")
        raise websocket_tls_guidance(verify)
      end

      # Force a debug capture even though the caller will also capture on error.
      capture_task_html(driver: driver, task_name: "dm_send_text_verify", status: "error", meta: verify)
      raise "Message not confirmed as sent (#{verify[:reason]})"
    end

    def find_visible_dm_textbox(driver)
      candidates = driver.find_elements(css: "div[role='textbox'][contenteditable='true']")
      candidates = driver.find_elements(css: "div[role='textbox']") if candidates.empty?

      candidates.find do |el|
        begin
          el.displayed?
        rescue Selenium::WebDriver::Error::StaleElementReferenceError
          false
        end
      end || candidates.first
    end

    def read_dm_textbox_text(driver)
      driver.execute_script(<<~JS)
        const textbox =
          document.querySelector("div[role='textbox'][contenteditable='true']") ||
          document.querySelector("div[role='textbox']");
        if (!textbox) return null;
        return (textbox.innerText || "").toString();
      JS
    rescue StandardError
      nil
    end

	    def verify_dm_send(driver, message_text, expected_username: nil)
	      needle = message_text.to_s.strip
	      return { ok: false, reason: "blank message_text" } if needle.blank?

      # Poll briefly because the UI can take a moment to append the outgoing bubble.
      last = nil
      40.times do |i|
	        # Try to keep the message list near the bottom so the newest outgoing bubble is mounted.
	        begin
	          driver.execute_script(<<~JS)
            const main =
              document.querySelector("div[role='main']") ||
              document.scrollingElement ||
              document.documentElement ||
              document.body;
            try { main.scrollTop = 1e9; } catch (e) {}
            try { window.scrollTo(0, document.body.scrollHeight); } catch (e) {}
          JS
        rescue StandardError
          nil
        end

	        last = driver.execute_script(<<~JS, needle, expected_username.to_s)
	          const needle = (arguments[0] || "").replace(/\\s+/g, " ").trim();
	          const expected = (arguments[1] || "").toLowerCase().trim();

          const norm = (s) => (s || "").replace(/\\s+/g, " ").trim();

          const textbox =
            document.querySelector("div[role='textbox'][contenteditable='true']") ||
            document.querySelector("div[role='textbox']");

          const textboxText = textbox ? norm(textbox.innerText) : null;
          const textboxEmpty = !textboxText || textboxText.length === 0;

	          // Common send failure surface text (best effort).
	          const bodyText = norm(document.body && document.body.innerText);
	          const sendError =
	            bodyText.includes("couldn't send") ||
	            bodyText.includes("could not send") ||
	            bodyText.includes("try again") && bodyText.includes("message");

	          const messageRequestInterstitial =
	            bodyText.includes("message request") ||
	            bodyText.includes("message requests") ||
	            (bodyText.includes("allow") && bodyText.includes("decline") && bodyText.includes("message"));

	          const alertTexts = Array.from(document.querySelectorAll("[role='alert'],[aria-live='polite'],[aria-live='assertive']"))
	            .map((n) => norm(n && (n.innerText || n.textContent)))
	            .filter((t) => t && t.length > 0)
	            .slice(0, 10);

	          // Best-effort: try to validate we are in the intended thread.
	          let threadMatches = null;
	          if (expected) {
	            const hrefs = Array.from(document.querySelectorAll("a[href^='/']"))
	              .map((a) => (a.getAttribute("href") || "").toLowerCase());
	            threadMatches = hrefs.some((h) => h === `/${expected}/` || h.startsWith(`/${expected}/`));
          }

          const nodes = Array.from(document.querySelectorAll(
            "div[role='row'], div[role='listitem'], [dir='auto'], span[data-lexical-text='true']"
          ));
          let bubbleFound = false;
          for (let i = nodes.length - 1; i >= 0 && i >= nodes.length - 400; i--) {
            const n = nodes[i];
            if (!n) continue;
            if (textbox && (textbox === n || textbox.contains(n) || n.contains(textbox))) continue;
            const t = norm(n.textContent || n.innerText);
            const a = norm(n.getAttribute && n.getAttribute("aria-label"));
            const combined = (t + " " + a).trim();
            if (combined && combined.includes(needle)) { bubbleFound = true; break; }
          }

	          return { textboxEmpty, textboxText, bubbleFound, threadMatches, sendError, messageRequestInterstitial, alertTexts };
	        JS

	        if last.is_a?(Hash) && last["sendError"] == true
	          return { ok: false, reason: "send_error_visible", details: last }
	        end

	        if last.is_a?(Hash) && last["messageRequestInterstitial"] == true
	          return { ok: false, reason: "message_request_interstitial_visible", details: last }
	        end

	        if last.is_a?(Hash) && last["textboxEmpty"] == true && last["bubbleFound"] == true
	          # If we can determine threadMatches, require it; otherwise accept.
	          if expected_username.to_s.strip.present?
	            tm = last["threadMatches"]
	            if tm.nil? || tm == true
	              return { ok: true, reason: "verified", details: last }
	            end
	          else
	            return { ok: true, reason: "verified", details: last }
	          end
	        end

	        sleep(0.75)

          # Fail fast if DM transport is broken at the browser/network layer.
          if (i % 4).zero?
            tls = detect_websocket_tls_issue(driver)
            if tls[:found]
              return {
                ok: false,
                reason: "websocket_tls_error #{tls[:reason]}",
                tls_issue: tls,
                details: last,
                expected_username: expected_username,
                message_preview: needle.byteslice(0, 80)
              }
            end
          end

	        # One refresh mid-way can help when the UI doesn't mount the most recent bubble immediately.
	        if i == 10
	          begin
	            driver.navigate.refresh
	            wait_for(driver, css: "body", timeout: 10)
	          rescue StandardError
	            nil
	          end
	        end
	      end

      tls = detect_websocket_tls_issue(driver)
      if tls[:found]
        return {
          ok: false,
          reason: "websocket_tls_error #{tls[:reason]}",
          tls_issue: tls,
          details: last,
          expected_username: expected_username,
          message_preview: needle.byteslice(0, 80)
        }
      end

      # If we couldn't find the bubble, but the textbox is empty, treat as "unknown" rather than success.
      textbox_empty = last.is_a?(Hash) ? last["textboxEmpty"] : nil
      bubble = last.is_a?(Hash) ? last["bubbleFound"] : nil
      thread = last.is_a?(Hash) ? last["threadMatches"] : nil

	      {
	        ok: false,
	        reason: "textbox_empty=#{textbox_empty.inspect} bubble_found=#{bubble.inspect} thread_matches=#{thread.inspect} message_request_interstitial=#{last.is_a?(Hash) ? last['messageRequestInterstitial'].inspect : 'nil'}",
	        details: last,
	        expected_username: expected_username,
	        message_preview: needle.byteslice(0, 80)
	      }
	    rescue StandardError => e
      { ok: false, reason: "verify_exception #{e.class}: #{e.message}" }
	    end

    def websocket_tls_guidance(verify)
      tls = verify[:tls_issue].to_h
      reason = tls[:reason].presence || "certificate validation error"
      "Instagram DM transport failed: #{reason}. "\
      "Chrome could not establish a trusted secure connection to Instagram chat endpoints. "\
      "Install/trust the system CA used by your network proxy or, for local debugging only, "\
      "set INSTAGRAM_CHROME_IGNORE_CERT_ERRORS=true and retry."
    end

    def detect_websocket_tls_issue(driver)
      return { found: false } unless driver.respond_to?(:logs)

      entries = driver.logs.get(:browser) rescue []
      messages = Array(entries).map { |e| e.message.to_s }

      # Common failure observed in this environment: the IG Direct gateway websocket fails TLS validation,
      # which can prevent DMs from actually being delivered even though the UI clears the composer.
      bad = messages.find { |m| m.include?("gateway.instagram.com/ws/streamcontroller") && m.include?("ERR_CERT_AUTHORITY_INVALID") }
      return { found: true, reason: "ERR_CERT_AUTHORITY_INVALID", message: bad.to_s.byteslice(0, 2000) } if bad

      other = messages.find { |m| m.include?("ERR_CERT_AUTHORITY_INVALID") }
      return { found: true, reason: "ERR_CERT_AUTHORITY_INVALID", message: other.to_s.byteslice(0, 2000) } if other

      { found: false }
    rescue StandardError => e
      { found: false, error: "#{e.class}: #{e.message}" }
    end

	    def click_dm_send_button(driver, textbox: nil)
	      return { clicked: false, reason: "no_textbox" } unless textbox
	      # Mark the send button in-DOM so we can click it via WebDriver actions (more reliable than JS click).
	      mark =
	        driver.execute_script(<<~JS, textbox)
	          const textbox = arguments[0];
	          if (!textbox) return { marked: false, reason: "no_textbox" };

	          // Clear previous marks (best effort).
	          try {
	            document.querySelectorAll("[data-codex-send-btn='1']").forEach((n) => n.removeAttribute("data-codex-send-btn"));
	          } catch (e) {}

	          const isVisible = (el) => {
	            if (!el) return false;
	            const style = window.getComputedStyle(el);
	            if (style.display === "none" || style.visibility === "hidden" || style.opacity === "0") return false;
	            const r = el.getBoundingClientRect();
	            return (r.width > 0 && r.height > 0);
	          };

	          const selectors = [
	            "[role='button'][aria-label='Send']",
	            "[role='button'][aria-label*='Send']",
	            "button[aria-label='Send']",
	            "button[aria-label*='Send']",
	            "svg[aria-label='Send']",
	            "svg[aria-label*='Send']"
	          ];

	          let root = textbox;
	          for (let depth = 0; depth < 10 && root; depth++) {
	            let candidate = null;
	            for (const sel of selectors) {
	              const el = root.querySelector ? root.querySelector(sel) : null;
	              if (el) { candidate = el; break; }
	            }

	            if (candidate) {
	              let button = candidate;
	              if (button && button.tagName && button.tagName.toLowerCase() === "svg") {
	                button = button.closest("button,[role='button']") || button;
	              }

	              const preview = (button && button.outerHTML ? button.outerHTML : "").slice(0, 900);
	              const ariaLabel = button && button.getAttribute ? button.getAttribute("aria-label") : null;
	              if (!button) return { marked: false, reason: "send_button_null" };
	              if (!isVisible(button)) return { marked: false, reason: "send_button_not_visible", ariaLabel, outerHTMLPreview: preview };

	              try { button.setAttribute("data-codex-send-btn", "1"); } catch (e) {}
	              return { marked: true, ariaLabel, outerHTMLPreview: preview };
	            }

	            root = root.parentElement;
	          }

	          return { marked: false, reason: "send_button_not_found_near_textbox" };
	        JS

	      mark = mark.to_h if mark.respond_to?(:to_h)
	      return { clicked: false, reason: "unexpected_js_return: #{mark.class}" } unless mark.is_a?(Hash)

	      mark = mark.transform_keys { |k| k.to_s.to_sym }
	      return { clicked: false, reason: mark[:reason] || "send_button_not_marked", aria_label: mark[:ariaLabel], outer_html_preview: mark[:outerHTMLPreview] } unless mark[:marked]

	      el = driver.find_element(css: "[data-codex-send-btn='1']")
	      begin
	        driver.action.move_to(el).click.perform
	      rescue StandardError
	        js_click(driver, el)
	      end

	      # Clean up the mark to avoid confusing later steps.
	      begin
	        driver.execute_script("arguments[0].removeAttribute('data-codex-send-btn');", el)
	      rescue StandardError
	        nil
	      end

	      { clicked: true, reason: "clicked", aria_label: mark[:ariaLabel], outer_html_preview: mark[:outerHTMLPreview] }
	    rescue StandardError => e
	      { clicked: false, reason: "send_click_exception #{e.class}: #{e.message}" }
	    end

    def normalize_username(value)
      value.to_s.strip.downcase.gsub(/[^a-z0-9._]/, "")
    end

    def normalize_count(value)
      text = value.to_s.strip
      return nil unless text.match?(/\A\d+\z/)

      text.to_i
    rescue StandardError
      nil
    end

    def extract_profile_follow_counts(html)
      # Best-effort; depends on English locale. Example:
      # "246 Followers, 661 Following, 37 Posts - See Instagram photos..."
      m = html.to_s.match(/content=\"\s*([\d,]+)\s*Followers,\s*([\d,]+)\s*Following\b/i)
      return nil unless m

      {
        followers: m[1].to_s.delete(",").to_i,
        following: m[2].to_s.delete(",").to_i
      }
    rescue StandardError
      nil
    end

    def extract_conversation_users_from_inbox_html(html)
      users = {}
      verify_segments = 0

      return [users, verify_segments] if html.blank?

      # Extract from the Lightspeed payload embedded in the inbox page. Example structure:
      #   ... "verifyContactRowExists", ... , "Display Name", ... , "username", [9], [9]]]
      #
      # We avoid DOM selectors here because the inbox is frequently rendered as role="button" rows
      # and the username often only appears inside embedded payloads.
      # In many builds the payload is itself a JSON-encoded string, so quotes appear as \"...\".
      segments = html.scan(/\\\"verifyContactRowExists\\\"[\s\S]{0,4000}?\[9\],\s*\[9\]\]\]/)
      segments = html.scan(/"verifyContactRowExists"[\s\S]{0,4000}?\[9\],\s*\[9\]\]\]/) if segments.empty?
      verify_segments += segments.length

      segments.each do |segment|
        # Candidate usernames appear lowercase in this payload (usernames are case-insensitive but stored normalized).
        token_re =
          if segment.include?("\\\"")
            /\\\"([A-Za-z0-9._]{1,30})\\\"/
          else
            /"([A-Za-z0-9._]{1,30})"/
          end

        tokens = segment.scan(token_re).flatten
        candidate_usernames = tokens.select { |t| t == t.downcase && t.match?(/\A[a-z0-9._]{1,30}\z/) }
        username = candidate_usernames.last.to_s
        next if username.blank?

        display_re =
          if segment.include?("\\\"")
            /\\\"([^\\\"]{1,80})\\\"/
          else
            /"([^"]{1,80})"/
          end

        display_candidates = segment.scan(display_re).flatten
        display = display_candidates.reverse.find do |t|
          next false if t.blank?
          next false if t.include?("/") || t.match?(%r{\Ahttps?://}i)
          next false if t.match?(/\A[a-z0-9._]{1,30}\z/) # likely a username token
          next false if t.match?(/\Amessaging\b/i) || t.match?(/\blightspeed\b/i) || t.match?(/\bmedia_fallback\b/i)
          true
        end

        users[normalize_username(username)] ||= { display_name: display.presence || username }
      end

      [users, verify_segments]
    rescue StandardError
      [users, verify_segments]
    end

    def extract_story_users_from_home_html(html)
      return [] if html.blank?

      # Try multiple preloader patterns with more aggressive matching
      patterns = [
        "adp_PolarisStoriesV3TrayContainerQueryRelayPreloader_",
        "adp_PolarisStoriesV",
        "StoriesTrayContainer", 
        "stories_tray",
        "story-tray",
        "StoryTray",
        "storyTray",
        "stories-container",
        "storiesContainer"
      ]
      
      idx = nil
      window = ""
      
      patterns.each do |pattern|
        idx = html.index(pattern)
        if idx
          window = html.byteslice(idx, 800_000) || ""
          break
        end
      end
      
      # If no preloader found, try direct username extraction from the entire HTML
      if idx.nil?
        # Look for any story-related patterns in the HTML
        story_patterns = [
          /\"username\":\"([A-Za-z0-9._]{1,30})\"[\s\S]{0,1000}\"has_story\":true/,
          /\"user\":\{[\s\S]{0,2000}\"username\":\"([A-Za-z0-9._]{1,30})\"[\s\S]{0,2000}\"has_?story\":\s*true/,
          /\"([A-Za-z0-9._]{1,30})\"[\s\S]{0,500}\"story\"/,
          /\/stories\/([A-Za-z0-9._]{1,30})\//
        ]
        
        usernames = []
        story_patterns.each do |pattern|
          matches = html.scan(pattern)
          if matches.is_a?(Array)
            matches = matches.flatten if matches.first.is_a?(Array)
            usernames.concat(matches)
          end
        end
        
        return usernames.map { |u| normalize_username(u) }.reject(&:blank?).uniq.take(12)
      end

      # Prefer story-tray item extraction
      tray_usernames = window.scan(/\"user\":\{[\s\S]{0,4000}?\"username\":\"([A-Za-z0-9._]{1,30})\"[\s\S]{0,4000}?\"uuid\":\"/).flatten
      tray_usernames = tray_usernames.map { |u| normalize_username(u) }.reject(&:blank?).uniq
      return tray_usernames unless tray_usernames.empty?

      # Fallback: grab usernames in this payload window
      usernames = window.scan(/\"username\":\"([A-Za-z0-9._]{1,30})\"/).flatten.map { |u| normalize_username(u) }
      usernames.reject(&:blank?).uniq
    rescue StandardError => e
      Rails.logger.error "Story extraction error: #{e.message}" if defined?(Rails)
      []
    end

    def source_for(username, conversation_users, story_users)
      in_conversation = conversation_users.key?(username)
      in_story = story_users.key?(username)

      return "conversation+story" if in_conversation && in_story
      return "story" if in_story

      "conversation"
    end

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

    def open_first_story_from_home_carousel!(driver:)
      started_at = Time.current
      deadline = started_at + 45.seconds  # Further increased timeout
      attempts = 0
      last_probe = {}
      prefetch_route_attempted = false
      excluded_usernames = []

      while Time.current < deadline
        attempts += 1
        dismiss_common_overlays!(driver)

        # Force scroll to ensure stories are loaded
        if attempts == 1
          begin
            driver.execute_script("window.scrollTo(0, 0);")
            sleep(1.0)
          rescue StandardError
            nil
          end
        end

        # Check if we're on the right page
        current_url = driver.current_url.to_s
        if !current_url.include?("instagram.com") && !current_url.include?(INSTAGRAM_BASE_URL)
          Rails.logger.warn "Not on Instagram page, redirecting. Current URL: #{current_url}" if defined?(Rails)
          begin
            driver.navigate.to(INSTAGRAM_BASE_URL)
            wait_for(driver, css: "body", timeout: 12)
            dismiss_common_overlays!(driver)
            sleep(2.0)
            next
          rescue StandardError => e
            Rails.logger.error "Failed to redirect to Instagram: #{e.message}" if defined?(Rails)
            next
          end
        end

        probe = detect_home_story_carousel_probe(driver, excluded_usernames: excluded_usernames)
        last_probe = probe

        # Enhanced debugging for failed story detection
        if attempts == 1 || (attempts % 3 == 0) || (probe[:target_count].to_i.zero? && probe[:anchor_count].to_i.zero? && probe[:prefetch_count].to_i.zero?)
          capture_task_html(
            driver: driver,
            task_name: "home_story_sync_debug_probe",
            status: "ok",
            meta: {
              attempts: attempts,
              target_count: probe[:target_count],
              anchor_count: probe[:anchor_count],
              prefetch_count: probe[:prefetch_count],
              target_strategy: probe[:target_strategy],
              debug_info: probe[:debug],
              page_debug: probe[:page_debug],
              current_url: current_url,
              all_zero: probe[:target_count].to_i.zero? && probe[:anchor_count].to_i.zero? && probe[:prefetch_count].to_i.zero?
            }
          )
        end

        # Aggressive prefetch route attempt when no elements found
        if !prefetch_route_attempted && attempts >= 2 && (probe[:anchor_count].to_i.zero? || probe[:target_count].to_i.zero?) && Array(probe[:prefetch_usernames]).present?
          prefetch_route_attempted = true
          opened = open_story_from_prefetch_usernames(
            driver: driver,
            usernames: Array(probe[:prefetch_usernames]),
            attempts: attempts,
            probe: probe
          )
          return true if opened
        end

        # Try direct navigation if no stories found after multiple attempts
        if attempts >= 6 && probe[:target_count].to_i.zero? && probe[:anchor_count].to_i.zero? && probe[:prefetch_count].to_i.zero?
          # Try to navigate to stories directly as last resort
          begin
            Rails.logger.info "No stories found, attempting refresh and retry" if defined?(Rails)
            driver.navigate.to("#{INSTAGRAM_BASE_URL}/")
            wait_for(driver, css: "body", timeout: 12)
            dismiss_common_overlays!(driver)
            sleep(2.0)
            next
          rescue StandardError
            nil
          end
        end

        target = probe[:target]
        if target
          clicked_target = false
          begin
            driver.action.move_to(target).click.perform
            clicked_target = true
          rescue StandardError
            begin
              js_click(driver, target)
              clicked_target = true
            rescue StandardError
              clicked_target = false
            end
          end

          if clicked_target
            sleep(0.8)
            dom = extract_story_dom_context(driver)
            unless story_viewer_ready?(dom)
              current_url = driver.current_url.to_s
              if current_url.include?("/live/")
                live_username = extract_username_from_profile_like_path(current_url)
                excluded_usernames << live_username if live_username.present? && !excluded_usernames.include?(live_username)
              end

              capture_task_html(
                driver: driver,
                task_name: "home_story_sync_first_story_opened",
                status: "error",
                meta: {
                  strategy: probe[:target_strategy],
                  attempts: attempts,
                  target_count: probe[:target_count],
                  anchor_count: probe[:anchor_count],
                  prefetch_story_usernames: probe[:prefetch_count],
                  reason: "clicked_target_but_story_frame_not_detected",
                  current_url: current_url,
                  excluded_usernames: excluded_usernames,
                  story_viewer_active: dom[:story_viewer_active],
                  story_frame_present: dom[:story_frame_present],
                  media_signature: dom[:media_signature].to_s.byteslice(0, 120),
                  debug_info: probe[:debug],
                  page_debug: probe[:page_debug]
                }
              )
              begin
                driver.navigate.to(INSTAGRAM_BASE_URL)
                wait_for(driver, css: "body", timeout: 12)
              rescue StandardError
                nil
              end
              next
            end

            capture_task_html(
              driver: driver,
              task_name: "home_story_sync_first_story_opened",
              status: "ok",
              meta: {
                strategy: probe[:target_strategy],
                attempts: attempts,
                target_count: probe[:target_count],
                anchor_count: probe[:anchor_count],
                prefetch_story_usernames: probe[:prefetch_count],
                debug_info: probe[:debug],
                page_debug: probe[:page_debug]
              }
            )
            return true
          end
        end

        # Some IG builds rerender story nodes and invalidate Selenium element handles between probe and click.
        # When we have candidates but no stable handle, click directly in page JS as a fallback.
        if probe[:target_count].to_i.positive?
          js_fallback = click_home_story_open_target_via_js(driver, excluded_usernames: excluded_usernames)
          if js_fallback[:clicked]
            sleep(0.8)
            dom = extract_story_dom_context(driver)
            if story_viewer_ready?(dom)
              capture_task_html(
                driver: driver,
                task_name: "home_story_sync_first_story_opened_js_fallback",
                status: "ok",
                meta: {
                  strategy: js_fallback[:strategy],
                    attempts: attempts,
                    target_count: js_fallback[:count],
                    anchor_count: probe[:anchor_count],
                    prefetch_story_usernames: probe[:prefetch_count],
                    excluded_usernames: excluded_usernames,
                    debug_info: probe[:debug],
                    page_debug: probe[:page_debug]
                  }
                )
                return true
              end
            end
        end

        # If no clickable tray anchors exist, open story route directly from prefetch usernames.
        if !prefetch_route_attempted && attempts >= 3 && Array(probe[:prefetch_usernames]).present?
          prefetch_route_attempted = true
          opened = open_story_from_prefetch_usernames(
            driver: driver,
            usernames: Array(probe[:prefetch_usernames]),
            attempts: attempts,
            probe: probe
          )
          return true if opened
        end

        sleep(1.0)
        # Story tray hydration can stall on initial render; one soft refresh helps recover.
        if attempts == 8 || attempts == 15
          begin
            driver.navigate.refresh
            wait_for(driver, css: "body", timeout: 12)
          rescue StandardError
            nil
          end
        end
      end

      capture_task_html(
        driver: driver,
        task_name: "home_story_sync_no_carousel_found",
        status: "error",
        meta: {
          attempts: attempts,
          elapsed_seconds: (Time.current - started_at).round(2),
          target_count: last_probe[:target_count],
          anchor_count: last_probe[:anchor_count],
          prefetch_story_usernames: last_probe[:prefetch_count],
          target_strategy: last_probe[:target_strategy],
          debug_info: last_probe[:debug],
          page_debug: last_probe[:page_debug],
          current_url: driver.current_url.to_s,
          page_title: begin
            driver.execute_script("return document.title;")
          rescue StandardError
            "unknown"
          end
        }
      )
      raise "No clickable active stories found in the home carousel after waiting #{(Time.current - started_at).round(1)}s (targets=#{last_probe[:target_count].to_i}, anchors=#{last_probe[:anchor_count].to_i}, prefetch=#{last_probe[:prefetch_count].to_i}, strategy=#{last_probe[:target_strategy]})"
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

    def click_next_story_in_carousel!(driver:, current_ref:)
      previous_signature = visible_story_media_signature(driver)
      marker = find_story_next_button(driver)
      capture_task_html(
        driver: driver,
        task_name: "home_story_sync_next_button_probe",
        status: marker[:found] ? "ok" : "error",
        meta: {
          current_ref: current_ref,
          next_found: marker[:found],
          selector: marker[:selector],
          aria_label: marker[:aria_label],
          outer_html_preview: marker[:outer_html_preview]
        }
      )

      if marker[:found]
        begin
          el = driver.find_element(css: "[data-codex-story-next='1']")
          driver.action.move_to(el).click.perform
        rescue StandardError
          begin
            el = driver.find_element(css: "[data-codex-story-next='1']")
            js_click(driver, el)
          rescue StandardError
            driver.action.send_keys(:arrow_right).perform
          end
        ensure
          begin
            driver.execute_script("const el=document.querySelector('[data-codex-story-next=\"1\"]'); if (el) el.removeAttribute('data-codex-story-next');")
          rescue StandardError
            nil
          end
        end
      else
        driver.action.send_keys(:arrow_right).perform
      end

      sleep(1.0)
      new_ref = current_story_reference(driver.current_url.to_s)
      new_signature = visible_story_media_signature(driver)
      moved = (new_ref.present? && new_ref != current_ref) || (new_signature.present? && previous_signature.present? && new_signature != previous_signature)

      capture_task_html(
        driver: driver,
        task_name: "home_story_sync_after_next_click",
        status: moved ? "ok" : "error",
        meta: {
          previous_ref: current_ref,
          new_ref: new_ref,
          previous_signature: previous_signature.to_s.byteslice(0, 120),
          new_signature: new_signature.to_s.byteslice(0, 120),
          moved: moved
        }
      )
      moved
    rescue StandardError => e
      capture_task_html(
        driver: driver,
        task_name: "home_story_sync_next_click_error",
        status: "error",
        meta: { previous_ref: current_ref, error_class: e.class.name, error_message: e.message }
      )
      false
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

    def find_story_next_button(driver)
      payload = driver.execute_script(<<~JS)
        const isVisible = (el) => {
          if (!el) return false;
          const s = window.getComputedStyle(el);
          if (!s || s.display === "none" || s.visibility === "hidden" || s.opacity === "0") return false;
          const r = el.getBoundingClientRect();
          return r.width > 6 && r.height > 6;
        };

        const candidates = [
          { sel: "button[aria-label='Next']", label: "button[aria-label='Next']" },
          { sel: "button[aria-label='Next story']", label: "button[aria-label='Next story']" },
          { sel: "[role='button'][aria-label='Next']", label: "[role='button'][aria-label='Next']" },
          { sel: "[role='button'][aria-label*='Next']", label: "[role='button'][aria-label*='Next']" },
          { sel: "svg[aria-label='Next']", label: "svg[aria-label='Next']" },
          { sel: "svg[aria-label*='Next']", label: "svg[aria-label*='Next']" }
        ];

        for (const c of candidates) {
          const nodes = Array.from(document.querySelectorAll(c.sel));
          const hit = nodes.find((n) => {
            const target = (n.tagName && n.tagName.toLowerCase() === "svg") ? (n.closest("button,[role='button']") || n) : n;
            return isVisible(target);
          });
          if (hit) {
            const target = (hit.tagName && hit.tagName.toLowerCase() === "svg") ? (hit.closest("button,[role='button']") || hit) : hit;
            try { target.setAttribute("data-codex-story-next", "1"); } catch (e) {}
            return {
              found: true,
              selector: c.label,
              aria_label: target.getAttribute("aria-label") || "",
              outer_html_preview: (target.outerHTML || "").slice(0, 800)
            };
          }
        }

        return { found: false, selector: "", aria_label: "", outer_html_preview: "" };
      JS

      return { found: false, selector: nil, aria_label: nil, outer_html_preview: nil } unless payload.is_a?(Hash)

      {
        found: payload["found"] == true,
        selector: payload["selector"].to_s.presence,
        aria_label: payload["aria_label"].to_s.presence,
        outer_html_preview: payload["outer_html_preview"].to_s.presence
      }
    rescue StandardError
      { found: false, selector: nil, aria_label: nil, outer_html_preview: nil }
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

    def mark_profile_dm_state!(profile:, state:, reason:, retry_after_at: nil)
      return unless profile

      can_message_value =
        case state.to_s
        when "messageable"
          true
        when "unknown"
          nil
        else
          false
        end

      payload = {
        can_message: can_message_value,
        restriction_reason: can_message_value == true ? nil : reason.to_s.presence,
        dm_interaction_state: state.to_s.presence,
        dm_interaction_reason: reason.to_s.presence,
        dm_interaction_checked_at: Time.current,
        dm_interaction_retry_after_at: retry_after_at
      }
      profile.update!(payload)
    rescue StandardError
      nil
    end

    def apply_dm_state_from_send_result(profile:, result:)
      return unless profile
      return unless result.is_a?(Hash)

      reason = result[:reason].to_s.presence || "send_failed"
      retry_after =
        if result[:api_http_status].to_i == 403
          Time.current + STORY_INTERACTION_RETRY_DAYS.days
        else
          Time.current + 12.hours
        end

      mark_profile_dm_state!(
        profile: profile,
        state: "unavailable",
        reason: reason,
        retry_after_at: retry_after
      )
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

    def with_task_capture(driver:, task_name:, meta: {})
      result = yield
      capture_task_html(driver: driver, task_name: task_name, status: "ok", meta: meta)
      result
    rescue StandardError => e
      capture_task_html(
        driver: driver,
        task_name: task_name,
        status: "error",
        meta: meta.merge(
          error_class: e.class.name,
          error_message: e.message,
          error_backtrace: Array(e.backtrace).take(40)
        )
      )
      raise
    end

    def capture_task_html(driver:, task_name:, status:, meta: {})
      timestamp = Time.current.utc.strftime("%Y%m%dT%H%M%S.%LZ")
      slug = task_name.to_s.downcase.gsub(/[^a-z0-9]+/, "_").gsub(/\A_|_\z/, "")
      root = DEBUG_CAPTURE_DIR.join(Time.current.utc.strftime("%Y%m%d"))
      FileUtils.mkdir_p(root)

      base = "#{timestamp}_#{slug}_#{status}"
      html_path = root.join("#{base}.html")
      json_path = root.join("#{base}.json")
      png_path = root.join("#{base}.png")

      html = begin
        driver.page_source.to_s
      rescue StandardError => e
        "<!-- unable to capture page_source: #{e.class}: #{e.message} -->"
      end

      metadata = {
        timestamp: Time.current.utc.iso8601(3),
        task_name: task_name,
        status: status,
        account_username: @account.username,
        current_url: safe_driver_value(driver) { driver.current_url },
        page_title: safe_driver_value(driver) { driver.title }
      }.merge(meta)

      # Best-effort capture of browser console logs. Not all driver builds support this.
      logs =
        safe_driver_value(driver) do
          next nil unless driver.respond_to?(:logs)
          types = driver.logs.available_types
          next nil unless types.include?(:browser) || types.include?("browser")

          driver.logs.get(:browser).map do |entry|
            {
              timestamp: entry.timestamp,
              level: entry.level,
              message: entry.message.to_s.byteslice(0, 2000)
            }
          end.last(200)
        end
      metadata[:browser_console] = logs if logs.present?

      perf =
        safe_driver_value(driver) do
          next nil unless driver.respond_to?(:logs)
          types = driver.logs.available_types
          next nil unless types.include?(:performance) || types.include?("performance")

          driver.logs.get(:performance).map do |entry|
            { timestamp: entry.timestamp, message: entry.message.to_s.byteslice(0, 20_000) }
          end.last(300)
        end
      if perf.present?
        metadata[:performance_summary] = summarize_performance_logs(perf)
        metadata[:performance_logs] = filter_performance_logs(perf)
      end

      # Screenshot helps catch transient toasts/overlays that aren't obvious from HTML.
      safe_driver_value(driver) do
        driver.save_screenshot(png_path.to_s)
        true
      end
      metadata[:screenshot] = png_path.to_s if File.exist?(png_path)

      File.write(html_path, html)
      File.write(json_path, JSON.pretty_generate(metadata))
    rescue StandardError => e
      Rails.logger.warn("Failed to write debug capture for #{task_name}: #{e.class}: #{e.message}")
    end

    def summarize_performance_logs(entries)
      # Chrome "performance" log entries are JSON strings.
      # We keep a small summary so the JSON artifacts stay readable.
      requests = []
      responses = {}

      Array(entries).each do |e|
        raw = e.is_a?(Hash) ? e[:message] || e["message"] : nil
        next if raw.blank?

        msg = JSON.parse(raw) rescue nil
        inner = msg.is_a?(Hash) ? msg["message"] : nil
        next unless inner.is_a?(Hash)

        method = inner["method"].to_s
        params = inner["params"].is_a?(Hash) ? inner["params"] : {}

        case method
        when "Network.requestWillBeSent"
          req = params["request"].is_a?(Hash) ? params["request"] : {}
          url = req["url"].to_s
          next if url.blank?
          next unless interesting_perf_url?(url)
          requests << { request_id: params["requestId"], url: url, http_method: req["method"] }
        when "Network.responseReceived"
          resp = params["response"].is_a?(Hash) ? params["response"] : {}
          url = resp["url"].to_s
          next if url.blank?
          next unless interesting_perf_url?(url)
          responses[params["requestId"].to_s] = { url: url, status: resp["status"], mime_type: resp["mimeType"] }
        end
      end

      recent = requests.last(40).map do |r|
        rid = r[:request_id].to_s
        r.merge(response: responses[rid])
      end

      {
        interesting_request_count: requests.size,
        recent_interesting: recent
      }
    rescue StandardError => e
      { error: "#{e.class}: #{e.message}" }
    end

    def filter_performance_logs(entries)
      # Keep only likely-relevant messages to avoid huge JSON artifacts.
      Array(entries).select do |e|
        raw = e.is_a?(Hash) ? e[:message] || e["message"] : nil
        next false if raw.blank?
        raw.include?("Network.requestWillBeSent") ||
          raw.include?("Network.responseReceived") ||
          raw.include?("Network.loadingFailed")
      end.last(200)
    end

    def interesting_perf_url?(url)
      u = url.to_s
      u.include?("/api/v1/") ||
        u.include?("/graphql") ||
        u.include?("/direct") ||
        u.include?("direct_v2") ||
        u.include?("broadcast")
    end

    def safe_driver_value(driver)
      yield
    rescue StandardError
      nil
    end

    def with_recoverable_session(label:, max_attempts: 2)
      attempt = 0

      begin
        attempt += 1
        yield
      rescue StandardError => e
        raise unless disconnected_session_error?(e)
        raise if attempt >= max_attempts

        Rails.logger.warn("Instagram #{label} recovered from browser disconnect (attempt #{attempt}/#{max_attempts}).")
        sleep(1)
        retry
      end
    end

    def disconnected_session_error?(error)
      return true if error.is_a?(Selenium::WebDriver::Error::InvalidSessionIdError)

      message = error.message.to_s.downcase
      message.include?("not connected to devtools") ||
        message.include?("session deleted as the browser has closed the connection") ||
        message.include?("disconnected")
    end
  end
end
