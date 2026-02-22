module Instagram
  class Client
    module FeedEngagementService
      # Captures "home feed" post identifiers with API-first retrieval.
      #
      # This does NOT auto-like or auto-comment. It only records posts, downloads media (temporarily),
      # and queues analysis. Interaction should remain a user-confirmed action in the UI.
      def capture_home_feed_posts!(rounds: 4, delay_seconds: 45, max_new: 20, starting_max_id: nil)
        rounds_i = rounds.to_i.clamp(1, 12)
        delay_i = delay_seconds.to_i.clamp(10, 120)
        max_new_i = max_new.to_i.clamp(1, 200)
        fetch_limit = [ max_new_i * 3, max_new_i ].max.clamp(12, 120)
        start_cursor = starting_max_id.to_s.strip.presence

        with_recoverable_session(label: "feed_capture") do
          with_authenticated_driver do |driver|
            with_task_capture(driver: driver, task_name: "feed_capture_home", meta: { rounds: rounds_i, delay_seconds: delay_i, max_new: max_new_i }) do
              driver.navigate.to(INSTAGRAM_BASE_URL)
              wait_for(driver, css: "body", timeout: 12)
              dismiss_common_overlays!(driver)
              retrieval = fetch_home_feed_items_for_capture(
                driver: driver,
                max_items: fetch_limit,
                max_pages: rounds_i,
                inter_page_delay_seconds: delay_i,
                starting_max_id: start_cursor
              )
              items = Array(retrieval[:items])

              seen = 0
              new_posts = 0
              updated_posts = 0
              queued_actions = 0
              skipped_posts = 0
              skipped_reasons = Hash.new(0)
              processed_shortcodes = Set.new

              items.each do |it|
                shortcode = it[:shortcode].to_s.strip
                next if shortcode.blank?
                next if processed_shortcodes.include?(shortcode)
                processed_shortcodes << shortcode

                seen += 1
                now = Time.current
                metadata = it[:metadata].is_a?(Hash) ? it[:metadata] : {}
                round_num = metadata["capture_page"].to_i
                round_num = 1 if round_num <= 0

                profile_resolution = resolve_feed_profile_for_action(item: it)
                profile = profile_resolution[:profile]
                skip_reason = profile_resolution[:reason].to_s.presence if profile.nil?
                skip_reason ||= feed_item_skip_reason(item: it)

                if skip_reason.blank? && profile
                  policy = Instagram::ProfileScanPolicy.new(profile: profile).decision
                  if ActiveModel::Type::Boolean.new.cast(policy[:skip_post_analysis])
                    reason_code = policy[:reason_code].to_s.presence || "policy_blocked"
                    skip_reason = "profile_policy_#{reason_code}"
                  end
                end

                persist_feed_cache_post!(
                  item: it,
                  profile: profile,
                  round: round_num,
                  captured_at: now,
                  skip_reason: skip_reason
                )

                if skip_reason.present?
                  skipped_posts += 1
                  skipped_reasons[skip_reason] += 1
                  next
                end

                profile_post_result = persist_feed_profile_post!(
                  profile: profile,
                  item: it,
                  round: round_num,
                  captured_at: now
                )
                profile_post = profile_post_result[:post]

                if profile_post_result[:created]
                  new_posts += 1
                  record_feed_profile_capture_event!(profile: profile, post: profile_post, captured_at: now)
                elsif profile_post_result[:updated]
                  updated_posts += 1
                end

                enqueue_result = enqueue_workspace_processing_for_feed_post!(profile: profile, post: profile_post)
                queued_actions += 1 if ActiveModel::Type::Boolean.new.cast(enqueue_result[:enqueued])
                break if new_posts >= max_new_i
              rescue StandardError => e
                skipped_posts += 1
                skipped_reasons["item_processing_error"] += 1
                Ops::StructuredLogger.warn(
                  event: "feed_capture_home.item_failed",
                  payload: {
                    instagram_account_id: @account.id,
                    shortcode: it[:shortcode].to_s,
                    author_username: it[:author_username].to_s,
                    error_class: e.class.name,
                    error_message: e.message.to_s.byteslice(0, 220)
                  }
                )
                next
              end

              result = {
                seen_posts: seen,
                new_posts: new_posts,
                updated_posts: updated_posts,
                queued_actions: queued_actions,
                skipped_posts: skipped_posts,
                skipped_reasons: skipped_reasons.sort.to_h,
                fetched_items: items.length,
                fetch_source: retrieval[:source].to_s.presence || "unknown",
                fetch_pages: retrieval[:pages_fetched].to_i,
                fetch_error: retrieval[:error].to_s.presence,
                next_max_id: retrieval[:next_max_id].to_s.presence,
                more_available: ActiveModel::Type::Boolean.new.cast(retrieval[:more_available]),
                starting_max_id: start_cursor
              }

              Ops::StructuredLogger.info(
                event: "feed_capture_home.completed",
                payload: result.merge(
                  instagram_account_id: @account.id,
                  rounds: rounds_i,
                  delay_seconds: delay_i,
                  max_new: max_new_i
                )
              )
              result
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

      private

      def fetch_home_feed_items_for_capture(driver:, max_items:, max_pages:, inter_page_delay_seconds:, starting_max_id: nil)
        start_cursor = starting_max_id.to_s.strip.presence
        api_error = nil
        if feed_capture_api_eligible?
          api_result = fetch_home_feed_items_via_api_paginated(
            limit: max_items,
            max_pages: max_pages,
            starting_max_id: start_cursor,
            inter_page_delay_seconds: inter_page_delay_seconds
          )
          return api_result if Array(api_result[:items]).any?
          api_error = api_result[:error].to_s.presence
        end

        dom_items = Array(extract_feed_items_from_dom(driver)).first(max_items.to_i)
        {
          source: "dom_fallback",
          pages_fetched: dom_items.any? ? 1 : 0,
          more_available: false,
          next_max_id: nil,
          error: api_error,
          items: dom_items
        }
      rescue StandardError => e
        {
          source: "dom_fallback",
          pages_fetched: 0,
          more_available: false,
          next_max_id: nil,
          error: e.message.to_s,
          items: []
        }
      end

      def feed_capture_api_eligible?
        return true if @account.respond_to?(:cookie_authenticated?) && @account.cookie_authenticated?

        @account.cookies.present?
      rescue StandardError
        false
      end

      def resolve_feed_profile_for_action(item:)
        username = normalize_username(item[:author_username].to_s)
        metadata = item[:metadata].is_a?(Hash) ? item[:metadata] : {}
        author_ig_user_id =
          item[:author_ig_user_id].to_s.strip.presence ||
          metadata["author_ig_user_id"].to_s.strip.presence

        profile = nil
        profile = @account.instagram_profiles.find_by(ig_user_id: author_ig_user_id) if author_ig_user_id.present?
        profile ||= @account.instagram_profiles.find_by(username: username) if username.present?

        if profile.nil? && relationship_fallback_allowed?(metadata: metadata)
          profile = build_fallback_profile_for_feed_item(username: username, author_ig_user_id: author_ig_user_id)
        end

        return { profile: nil, reason: "profile_missing" } unless profile

        sync_profile_relationship_hints!(profile: profile, metadata: metadata, author_ig_user_id: author_ig_user_id)

        relationship_known =
          profile.following || profile.follows_you ||
            relationship_hint_positive?(metadata: metadata)
        unless relationship_known
          return { profile: nil, reason: "profile_not_in_follow_graph" } unless relationship_fallback_allowed?(metadata: metadata)
        end

        { profile: profile, reason: nil }
      rescue StandardError
        { profile: nil, reason: "profile_lookup_failed" }
      end

      def feed_item_skip_reason(item:)
        metadata = item[:metadata].is_a?(Hash) ? item[:metadata] : {}
        post_kind = item[:post_kind].to_s.downcase
        product_type = metadata["product_type"].to_s.downcase

        return "missing_shortcode" if item[:shortcode].to_s.strip.blank?
        return "missing_media_url" if item[:media_url].to_s.strip.blank?
        return "story_content" if post_kind == "story" || product_type == "story" || ActiveModel::Type::Boolean.new.cast(metadata["is_story"])
        return "sponsored_or_ad" if metadata["ad_id"].to_s.present? || ActiveModel::Type::Boolean.new.cast(metadata["is_paid_partnership"])
        if ActiveModel::Type::Boolean.new.cast(metadata["is_suggested"]) ||
            ActiveModel::Type::Boolean.new.cast(metadata["has_suggestion_context"]) ||
            metadata["suggestion_context"].to_s.present?
          return "suggested_or_irrelevant"
        end

        nil
      rescue StandardError
        "invalid_feed_item"
      end

      def relationship_hint_positive?(metadata:)
        return true if ActiveModel::Type::Boolean.new.cast(metadata["author_following"])
        return true if ActiveModel::Type::Boolean.new.cast(metadata["author_followed_by"])

        false
      rescue StandardError
        false
      end

      def relationship_fallback_allowed?(metadata:)
        return false unless metadata.to_h["source"].to_s == "api_timeline"
        return false if ActiveModel::Type::Boolean.new.cast(ENV.fetch("FEED_CAPTURE_REQUIRE_FOLLOW_GRAPH", "false"))
        return false unless follow_graph_unavailable_for_account?

        true
      rescue StandardError
        false
      end

      def follow_graph_unavailable_for_account?
        return @follow_graph_unavailable_for_account unless @follow_graph_unavailable_for_account.nil?

        total_profiles = @account.instagram_profiles.count
        if total_profiles < 25
          @follow_graph_unavailable_for_account = false
          return false
        end

        has_relationships =
          @account.instagram_profiles
            .where("following = ? OR follows_you = ?", true, true)
            .limit(1)
            .exists?
        @follow_graph_unavailable_for_account = !has_relationships
      rescue StandardError
        @follow_graph_unavailable_for_account = false
      end

      def build_fallback_profile_for_feed_item(username:, author_ig_user_id:)
        uname = normalize_username(username.to_s)
        return nil if uname.blank?

        profile = @account.instagram_profiles.find_or_initialize_by(username: uname)
        return profile if profile.persisted? && (profile.following || profile.follows_you)

        attrs = { last_synced_at: Time.current }
        attrs[:ig_user_id] = author_ig_user_id if author_ig_user_id.to_s.present? && profile.ig_user_id.to_s.blank?
        profile.assign_attributes(attrs)
        profile.save! if profile.new_record? || profile.changed?
        profile
      rescue StandardError
        nil
      end

      def sync_profile_relationship_hints!(profile:, metadata:, author_ig_user_id:)
        return unless profile

        attrs = {}
        if author_ig_user_id.to_s.present? && profile.ig_user_id.to_s.blank?
          attrs[:ig_user_id] = author_ig_user_id
        end
        if ActiveModel::Type::Boolean.new.cast(metadata["author_following"]) && !profile.following
          attrs[:following] = true
        end
        if ActiveModel::Type::Boolean.new.cast(metadata["author_followed_by"]) && !profile.follows_you
          attrs[:follows_you] = true
        end
        attrs[:last_synced_at] = Time.current if attrs.any?
        profile.update!(attrs) if attrs.any?
      rescue StandardError
        nil
      end

      def persist_feed_cache_post!(item:, profile:, round:, captured_at:, skip_reason: nil)
        shortcode = item[:shortcode].to_s.strip
        return nil if shortcode.blank?

        post = @account.instagram_posts.find_or_initialize_by(shortcode: shortcode)
        is_new = post.new_record?
        metadata = post.metadata.is_a?(Hash) ? post.metadata.deep_dup : {}
        incoming_metadata = item[:metadata].is_a?(Hash) ? item[:metadata] : {}

        post.detected_at ||= captured_at
        post.taken_at ||= item[:taken_at].presence || captured_at
        post.post_kind = item[:post_kind].presence || post.post_kind.presence || "unknown"
        post.author_username = item[:author_username].presence || post.author_username
        post.author_ig_user_id = item[:author_ig_user_id].to_s.presence || metadata["author_ig_user_id"].to_s.presence || post.author_ig_user_id
        post.instagram_profile = profile if profile
        post.media_url = item[:media_url].presence || post.media_url
        post.caption = item[:caption].presence || post.caption
        post.metadata = metadata.merge(incoming_metadata).merge(
          "source" => "feed_capture_home",
          "round" => round.to_i,
          "captured_at" => captured_at.utc.iso8601(3),
          "author_ig_user_id" => post.author_ig_user_id.to_s.presence,
          "skip_reason" => skip_reason.to_s.presence,
          "skip_recorded_at" => skip_reason.to_s.present? ? captured_at.utc.iso8601(3) : nil
        )
        if skip_reason.to_s.blank?
          post.metadata.delete("skip_reason")
          post.metadata.delete("skip_recorded_at")
        end
        post.save! if post.changed?

        if is_new && skip_reason.to_s.blank?
          DownloadInstagramPostMediaJob.perform_later(instagram_post_id: post.id) if post.media_url.present?
          AnalyzeInstagramPostJob.perform_later(instagram_post_id: post.id)
        end

        post
      rescue StandardError
        nil
      end

      def annotate_feed_cache_skip_reason!(post:, reason:)
        return unless post&.persisted?
        return if reason.to_s.blank?

        metadata = post.metadata.is_a?(Hash) ? post.metadata.deep_dup : {}
        metadata["skip_reason"] = reason.to_s
        metadata["skip_recorded_at"] = Time.current.utc.iso8601(3)
        post.update!(metadata: metadata)
      rescue StandardError
        nil
      end

      def persist_feed_profile_post!(profile:, item:, round:, captured_at:)
        shortcode = item[:shortcode].to_s.strip
        raise "shortcode is required for feed profile post persist" if shortcode.blank?

        post = profile.instagram_profile_posts.find_or_initialize_by(shortcode: shortcode)
        was_new = post.new_record?
        existing_metadata = post.metadata.is_a?(Hash) ? post.metadata.deep_dup : {}
        incoming_metadata = item[:metadata].is_a?(Hash) ? item[:metadata] : {}

        incoming_post_kind = item[:post_kind].to_s.presence || incoming_metadata["post_kind"].to_s.presence || "post"
        incoming_media_url = item[:media_url].to_s.strip.presence
        incoming_caption = item[:caption].to_s.presence
        incoming_taken_at =
          begin
            raw = item[:taken_at]
            raw.is_a?(Time) ? raw : raw.present? ? Time.zone.parse(raw.to_s) : nil
          rescue StandardError
            nil
          end

        analysis_refresh_needed =
          was_new ||
          (incoming_media_url.present? && incoming_media_url != post.source_media_url.to_s) ||
          (incoming_caption.present? && incoming_caption != post.caption.to_s) ||
          incoming_post_kind.to_s != existing_metadata["post_kind"].to_s

        feed_state = existing_metadata["feed_capture_home"].is_a?(Hash) ? existing_metadata["feed_capture_home"].deep_dup : {}
        feed_state["first_seen_at"] ||= captured_at.utc.iso8601(3)
        feed_state["last_seen_at"] = captured_at.utc.iso8601(3)
        feed_state["last_round"] = round.to_i
        feed_state["author_username"] = item[:author_username].to_s.presence || profile.username
        feed_state["author_ig_user_id"] = item[:author_ig_user_id].to_s.presence || incoming_metadata["author_ig_user_id"].to_s.presence

        merged_metadata = existing_metadata.merge(incoming_metadata).merge(
          "source" => "feed_capture_home",
          "post_kind" => incoming_post_kind,
          "media_url" => incoming_media_url,
          "author_ig_user_id" => feed_state["author_ig_user_id"],
          "feed_capture_home" => feed_state
        )
        merged_metadata.delete("deleted_from_source")
        merged_metadata.delete("deleted_detected_at")
        merged_metadata.delete("deleted_reason")

        post.instagram_account = @account
        post.taken_at = incoming_taken_at || post.taken_at || captured_at
        post.caption = incoming_caption || post.caption
        post.permalink = resolve_feed_permalink(shortcode: shortcode, item: item, current_permalink: post.permalink)
        post.source_media_url = incoming_media_url || post.source_media_url
        post.likes_count = [ post.likes_count.to_i, incoming_metadata["like_count"].to_i ].max
        post.comments_count = [ post.comments_count.to_i, incoming_metadata["comment_count"].to_i ].max
        post.last_synced_at = captured_at
        post.metadata = merged_metadata

        if analysis_refresh_needed && (post.ai_status.to_s != "pending" || post.analyzed_at.present?)
          post.ai_status = "pending"
          post.analyzed_at = nil
        end

        post.save! if post.changed?
        { post: post, created: was_new, updated: (!was_new && post.previous_changes.present?) }
      end

      def resolve_feed_permalink(shortcode:, item:, current_permalink:)
        metadata = item[:metadata].is_a?(Hash) ? item[:metadata] : {}
        href = metadata["href"].to_s
        return "#{INSTAGRAM_BASE_URL}#{href}" if href.start_with?("/p/", "/reel/")

        kind = item[:post_kind].to_s.downcase
        return current_permalink if current_permalink.to_s.present?
        return "#{INSTAGRAM_BASE_URL}/reel/#{shortcode}/" if kind == "reel"

        "#{INSTAGRAM_BASE_URL}/p/#{shortcode}/"
      rescue StandardError
        current_permalink.to_s.presence || "#{INSTAGRAM_BASE_URL}/p/#{shortcode}/"
      end

      def record_feed_profile_capture_event!(profile:, post:, captured_at:)
        metadata = post.metadata.is_a?(Hash) ? post.metadata : {}
        profile.record_event!(
          kind: "profile_post_captured",
          external_id: "profile_post_captured:#{post.shortcode}",
          occurred_at: post.taken_at || captured_at,
          metadata: {
            source: "feed_capture_home",
            reason: "new_capture",
            shortcode: post.shortcode,
            instagram_profile_post_id: post.id,
            permalink: post.permalink_url,
            media_type: metadata["media_type"],
            media_id: metadata["media_id"],
            deleted_from_source: false
          }
        )
      rescue StandardError
        nil
      end

      def enqueue_workspace_processing_for_feed_post!(profile:, post:)
        return { enqueued: false, reason: "post_missing" } unless profile && post

        if post.source_media_url.to_s.present? || post.media.attached?
          DownloadInstagramProfilePostMediaJob.perform_later(
            instagram_account_id: @account.id,
            instagram_profile_id: profile.id,
            instagram_profile_post_id: post.id,
            trigger_analysis: false
          )
        end

        WorkspaceProcessActionsTodoPostJob.enqueue_if_needed!(
          account: @account,
          profile: profile,
          post: post,
          requested_by: "feed_capture_home"
        )
      rescue StandardError => e
        {
          enqueued: false,
          reason: "workspace_enqueue_failed",
          error_class: e.class.name,
          error_message: e.message.to_s
        }
      end
    end
  end
end
