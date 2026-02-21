module Ai
  class ProfileHistoryBuildService
    TARGET_ANALYZED_POSTS = 20
    TARGET_CAPTURED_POSTS = 50
    COLLECTION_COMMENTS_LIMIT = 20
    FACE_RECENCY_REFRESH_DAYS = 7
    FACE_REFRESH_MAX_ENQUEUE_PER_RUN = ENV.fetch("PROFILE_HISTORY_FACE_REFRESH_MAX_ENQUEUE_PER_RUN", "6").to_i.clamp(1, 20)
    FACE_REFRESH_PENDING_WINDOW_HOURS = ENV.fetch("PROFILE_HISTORY_FACE_REFRESH_PENDING_WINDOW_HOURS", "6").to_i.clamp(1, 24)
    FACE_VERIFICATION_MIN_APPEARANCES = FaceIdentityResolutionService::MIN_PRIMARY_APPEARANCES
    FACE_VERIFICATION_MIN_RATIO = FaceIdentityResolutionService::MIN_PRIMARY_RATIO

    PROFILE_INCOMPLETE_REASON_CODES =
      if defined?(ProcessPostMetadataTaggingJob::PROFILE_INCOMPLETE_REASON_CODES)
        ProcessPostMetadataTaggingJob::PROFILE_INCOMPLETE_REASON_CODES
      else
        %w[
          latest_posts_not_analyzed
          insufficient_analyzed_posts
          no_recent_posts_available
          missing_structured_post_signals
          profile_preparation_failed
          profile_preparation_error
        ].freeze
      end

    def initialize(
      account:,
      profile:,
      collector: nil,
      face_identity_resolution_service: FaceIdentityResolutionService.new
    )
      @account = account
      @profile = profile
      @collector = collector
      @face_identity_resolution_service = face_identity_resolution_service
    end

    def execute!
      policy_decision = Instagram::ProfileScanPolicy.new(profile: @profile).decision
      if ActiveModel::Type::Boolean.new.cast(policy_decision[:skip_post_analysis])
        return persist_and_result!(
          status: "blocked",
          ready: false,
          reason_code: policy_decision[:reason_code].to_s.presence || "profile_scan_policy_blocked",
          reason: policy_decision[:reason].to_s.presence || "Profile is blocked by scan policy.",
          checks: default_checks,
          queue_state: default_queue_state,
          preparation: {},
          face_verification: default_face_verification,
          conversation: default_conversation_state(ready: false)
        )
      end

      collection = collect_posts
      latest_50_posts = active_posts_scope.recent_first.limit(TARGET_CAPTURED_POSTS).to_a
      latest_20_posts = active_posts_scope.recent_first.limit(TARGET_ANALYZED_POSTS).to_a

      checks = build_capture_checks(collection: collection, latest_50_posts: latest_50_posts, latest_20_posts: latest_20_posts)
      download_queue = queue_missing_media_downloads(posts: latest_50_posts)
      analysis_queue = queue_missing_post_analysis(posts: latest_20_posts)
      preparation = prepare_history_summary(latest_20_posts: latest_20_posts)
      face_verification =
        if face_verification_ready_for_refresh?(checks: checks, analysis_queue: analysis_queue)
          verify_face_identity(latest_posts: latest_50_posts)
        else
          deferred_face_verification(
            reason_code: "latest_posts_not_analyzed",
            reason: "Face verification is deferred until recent post analysis is complete."
          )
        end
      queue_state = build_queue_state(
        download_queue: download_queue,
        analysis_queue: analysis_queue,
        face_refresh_queue: face_refresh_queue_state(face_verification: face_verification)
      )
      queue_work_pending = queue_state["downloads_queued"].to_i.positive? ||
        queue_state["downloads_pending"].to_i.positive? ||
        queue_state["analyses_queued"].to_i.positive? ||
        queue_state["analyses_pending"].to_i.positive? ||
        queue_state["face_refresh_queued"].to_i.positive? ||
        queue_state["face_refresh_pending"].to_i.positive? ||
        queue_state["face_refresh_deferred"].to_i.positive?
      preparation_ready = ActiveModel::Type::Boolean.new.cast(preparation["ready_for_comment_generation"])
      face_ready = ActiveModel::Type::Boolean.new.cast(face_verification["confirmed"])

      history_ready = checks.values.all? { |row| ActiveModel::Type::Boolean.new.cast(row["ready"]) } &&
        !queue_work_pending &&
        preparation_ready &&
        face_ready

      reason_code, reason = resolve_reason(
        checks: checks,
        queue_state: queue_state,
        preparation: preparation,
        face_verification: face_verification,
        history_ready: history_ready
      )
      conversation = build_conversation_state(ready: history_ready)

      persist_and_result!(
        status: history_ready ? "ready" : "pending",
        ready: history_ready,
        reason_code: reason_code,
        reason: reason,
        checks: checks,
        queue_state: queue_state,
        preparation: preparation,
        face_verification: face_verification,
        conversation: conversation
      )
    rescue StandardError => e
      persist_and_result!(
        status: "pending",
        ready: false,
        reason_code: "history_build_failed",
        reason: e.message.to_s,
        checks: default_checks,
        queue_state: default_queue_state,
        preparation: {
          "ready_for_comment_generation" => false,
          "reason_code" => "profile_preparation_error",
          "reason" => e.message.to_s
        },
        face_verification: default_face_verification,
        conversation: default_conversation_state(ready: false)
      )
    end

    private

    def collect_posts
      collector = @collector || Instagram::ProfileAnalysisCollector.new(account: @account, profile: @profile)
      collector.collect_and_persist!(
        posts_limit: nil,
        comments_limit: COLLECTION_COMMENTS_LIMIT,
        track_missing_as_deleted: true,
        sync_source: "profile_history_build",
        download_media: false
      )
    rescue StandardError => e
      {
        summary: {
          feed_fetch: {},
          collection_error: "#{e.class}: #{e.message}"
        }
      }
    end

    def build_capture_checks(collection:, latest_50_posts:, latest_20_posts:)
      summary = collection.is_a?(Hash) ? collection[:summary] : {}
      summary = {} unless summary.is_a?(Hash)
      feed_fetch = summary[:feed_fetch].is_a?(Hash) ? summary[:feed_fetch] : {}
      feed_fetch = summary["feed_fetch"] if feed_fetch.blank? && summary["feed_fetch"].is_a?(Hash)
      feed_fetch ||= {}

      more_available = ActiveModel::Type::Boolean.new.cast(feed_fetch["more_available"] || feed_fetch[:more_available])
      collection_error = summary[:collection_error].to_s.presence || summary["collection_error"].to_s.presence
      feed_available = feed_fetch.present?
      all_posts_captured = feed_available && !more_available && collection_error.blank?

      active_count = active_posts_scope.count
      expected_50 = [ active_count, TARGET_CAPTURED_POSTS ].min
      latest_50_ready = expected_50.positive? && latest_50_posts.length >= expected_50
      latest_50_reason_code =
        if expected_50.zero?
          "no_recent_posts_available"
        elsif latest_50_ready
          "ok"
        else
          "latest_50_posts_not_captured"
        end

      expected_20 = [ active_count, TARGET_ANALYZED_POSTS ].min
      analyzed_recent_20 = latest_20_posts.count { |post| post_analyzed?(post) }
      latest_20_ready = expected_20.positive? && analyzed_recent_20 >= expected_20
      latest_20_reason_code =
        if expected_20.zero?
          "no_recent_posts_available"
        elsif latest_20_ready
          "ok"
        else
          "latest_posts_not_analyzed"
        end

      {
        "all_posts_captured" => {
          "ready" => all_posts_captured,
          "reason_code" => all_posts_captured ? "ok" : "all_posts_not_yet_captured",
          "captured_posts_count" => active_count,
          "more_available" => more_available,
          "source" => feed_fetch["source"] || feed_fetch[:source],
          "pages_fetched" => feed_fetch["pages_fetched"] || feed_fetch[:pages_fetched],
          "feed_available" => feed_available,
          "collection_error" => collection_error
        }.compact,
        "latest_50_captured" => {
          "ready" => latest_50_ready,
          "reason_code" => latest_50_reason_code,
          "expected_count" => expected_50,
          "captured_count" => latest_50_posts.length
        },
        "latest_20_analyzed" => {
          "ready" => latest_20_ready,
          "reason_code" => latest_20_reason_code,
          "expected_count" => expected_20,
          "analyzed_count" => analyzed_recent_20
        }
      }
    end

    def queue_missing_media_downloads(posts:)
      queued_count = 0
      pending_count = 0
      skipped_count = 0
      failures = []
      post_ids = []

      Array(posts).each do |post|
        next unless post
        next if post.media.attached?

        unless downloadable_post?(post)
          skipped_count += 1
          next
        end

        if media_download_in_flight?(post)
          pending_count += 1
          next
        end

        job = DownloadInstagramProfilePostMediaJob.perform_later(
          instagram_account_id: @account.id,
          instagram_profile_id: @profile.id,
          instagram_profile_post_id: post.id,
          trigger_analysis: true
        )
        queued_count += 1
        post_ids << post.id
        mark_history_build_metadata!(
          post: post,
          attributes: {
            "media_download_job_id" => job.job_id,
            "media_download_queued_at" => Time.current.iso8601(3)
          }
        )
      rescue StandardError => e
        failures << {
          "instagram_profile_post_id" => post&.id,
          "shortcode" => post&.shortcode.to_s.presence,
          "error_class" => e.class.name,
          "error_message" => e.message.to_s.byteslice(0, 220)
        }.compact
      end

      {
        queued_count: queued_count,
        pending_count: pending_count,
        skipped_count: skipped_count,
        queued_post_ids: post_ids,
        failures: failures
      }
    end

    def queue_missing_post_analysis(posts:)
      queued_count = 0
      pending_count = 0
      skipped_count = 0
      failures = []
      post_ids = []

      Array(posts).each do |post|
        next unless post

        if post_analyzed?(post)
          skipped_count += 1
          next
        end
        unless post.media.attached?
          pending_count += 1
          next
        end
        if post_analysis_in_flight?(post)
          pending_count += 1
          next
        end

        job = AnalyzeInstagramProfilePostJob.perform_later(
          instagram_account_id: @account.id,
          instagram_profile_id: @profile.id,
          instagram_profile_post_id: post.id,
          task_flags: {
            generate_comments: false,
            enforce_comment_evidence_policy: false,
            retry_on_incomplete_profile: false
          }
        )
        queued_count += 1
        post_ids << post.id
        mark_history_build_metadata!(
          post: post,
          attributes: {
            "post_analysis_job_id" => job.job_id,
            "post_analysis_queued_at" => Time.current.iso8601(3)
          }
        )
      rescue StandardError => e
        failures << {
          "instagram_profile_post_id" => post&.id,
          "shortcode" => post&.shortcode.to_s.presence,
          "error_class" => e.class.name,
          "error_message" => e.message.to_s.byteslice(0, 220)
        }.compact
      end

      {
        queued_count: queued_count,
        pending_count: pending_count,
        skipped_count: skipped_count,
        queued_post_ids: post_ids,
        failures: failures
      }
    end

    def build_queue_state(download_queue:, analysis_queue:, face_refresh_queue: {})
      {
        "downloads_queued" => download_queue[:queued_count].to_i,
        "downloads_pending" => download_queue[:pending_count].to_i,
        "downloads_skipped" => download_queue[:skipped_count].to_i,
        "analysis_failures" => Array(download_queue[:failures]).first(20),
        "analyses_queued" => analysis_queue[:queued_count].to_i,
        "analyses_pending" => analysis_queue[:pending_count].to_i,
        "analyses_skipped" => analysis_queue[:skipped_count].to_i,
        "analysis_queue_failures" => Array(analysis_queue[:failures]).first(20),
        "face_refresh_queued" => face_refresh_queue[:queued_count].to_i,
        "face_refresh_pending" => face_refresh_queue[:pending_count].to_i,
        "face_refresh_deferred" => face_refresh_queue[:deferred_count].to_i,
        "face_refresh_failures" => Array(face_refresh_queue[:failures]).first(20)
      }
    end

    def prepare_history_summary(latest_20_posts:)
      collector = ExistingPostsCollector.new(posts: latest_20_posts)
      Ai::ProfileCommentPreparationService.new(
        account: @account,
        profile: @profile,
        posts_limit: TARGET_ANALYZED_POSTS,
        comments_limit: COLLECTION_COMMENTS_LIMIT,
        analyze_missing_posts: false,
        collector: collector
      ).prepare!(force: true)
    rescue StandardError => e
      {
        "ready_for_comment_generation" => false,
        "reason_code" => "profile_preparation_error",
        "reason" => e.message.to_s,
        "error_class" => e.class.name
      }
    end

    def face_verification_ready_for_refresh?(checks:, analysis_queue:)
      latest_20_ready = ActiveModel::Type::Boolean.new.cast(checks.dig("latest_20_analyzed", "ready"))
      return false unless latest_20_ready

      analysis_queue[:queued_count].to_i.zero? && analysis_queue[:pending_count].to_i.zero?
    rescue StandardError
      false
    end

    def deferred_face_verification(reason_code:, reason:)
      payload = default_face_verification
      payload["reason_code"] = reason_code.to_s.presence || "face_verification_deferred"
      payload["reason"] = reason.to_s.presence || "Face verification deferred."
      payload
    rescue StandardError
      default_face_verification
    end

    def verify_face_identity(latest_posts:)
      refresh_queue = {
        "queued_count" => 0,
        "pending_count" => 0,
        "deferred_count" => 0,
        "failures" => []
      }
      eligible_posts = Array(latest_posts).select { |post| post_analyzed?(post) && post.media.attached? }

      eligible_posts.each do |post|
        if face_refresh_required?(post: post)
          if face_refresh_in_flight?(post: post)
            refresh_queue["pending_count"] = refresh_queue["pending_count"].to_i + 1
            next
          end

          if refresh_queue["queued_count"].to_i >= FACE_REFRESH_MAX_ENQUEUE_PER_RUN
            refresh_queue["deferred_count"] = refresh_queue["deferred_count"].to_i + 1
            next
          end

          enqueue_state = enqueue_face_refresh_for_post(post: post)
          if enqueue_state[:queued]
            refresh_queue["queued_count"] = refresh_queue["queued_count"].to_i + 1
          else
            refresh_queue["failures"] << {
              "instagram_profile_post_id" => post.id,
              "shortcode" => post.shortcode.to_s.presence,
              "error_class" => enqueue_state[:error_class].to_s.presence || "enqueue_failed",
              "error_message" => enqueue_state[:error_message].to_s.byteslice(0, 220)
            }.compact
          end
          next
        end

        resolve_identity_for_post!(post: post) if post.instagram_post_faces.exists?
      end

      refresh_queue["failures"] = Array(refresh_queue["failures"]).first(20)

      counts = InstagramPostFace.joins(:instagram_profile_post)
        .where(instagram_profile_posts: { instagram_profile_id: @profile.id })
        .where.not(instagram_story_person_id: nil)
        .group(:instagram_story_person_id)
        .count
      total_faces = counts.values.sum.to_i

      if total_faces <= 0
        return {
          "confirmed" => false,
          "reason_code" => "insufficient_face_data",
          "reason" => "No detected faces were available for identity verification.",
          "total_faces" => 0,
          "reference_face_count" => 0,
          "dominance_ratio" => 0.0,
          "combined_faces" => [],
          "refresh_queue" => refresh_queue
        }
      end

      profile_username = normalize_username(@profile.username)
      people = @profile.instagram_story_people.where(id: counts.keys).index_by(&:id)
      combined = counts.sort_by { |_id, count| -count.to_i }.map do |person_id, appearances|
        person = people[person_id]
        linked = linked_usernames_for(person)
        label_username = normalize_username(person&.label)
        owner_match = linked.include?(profile_username) || label_username == profile_username || person&.role.to_s == "primary_user"

        {
          "person_id" => person_id,
          "label" => person&.display_label.to_s.presence || "person_#{person_id}",
          "role" => person&.role.to_s.presence || "unknown",
          "appearances" => appearances.to_i,
          "linked_usernames" => linked,
          "owner_match" => owner_match
        }
      end

      reference_face_count = combined.sum { |row| row["owner_match"] ? row["appearances"].to_i : 0 }
      dominance_ratio = total_faces.positive? ? (reference_face_count.to_f / total_faces.to_f).round(4) : 0.0
      confirmed = reference_face_count >= FACE_VERIFICATION_MIN_APPEARANCES && dominance_ratio >= FACE_VERIFICATION_MIN_RATIO

      reason_code =
        if confirmed
          "identity_confirmed"
        elsif reference_face_count < FACE_VERIFICATION_MIN_APPEARANCES
          "insufficient_reference_face_appearances"
        else
          "identity_match_ratio_too_low"
        end

      reason =
        if confirmed
          "Reference face verification confirms this face belongs to @#{@profile.username}."
        else
          "Reference face verification did not reach the required confidence threshold."
        end

      {
        "confirmed" => confirmed,
        "reason_code" => reason_code,
        "reason" => reason,
        "total_faces" => total_faces,
        "reference_face_count" => reference_face_count,
        "dominance_ratio" => dominance_ratio,
        "combined_faces" => combined.first(12),
        "refresh_queue" => refresh_queue
      }
    rescue StandardError => e
      {
        "confirmed" => false,
        "reason_code" => "face_verification_error",
        "reason" => e.message.to_s,
        "error_class" => e.class.name,
        "total_faces" => 0,
        "reference_face_count" => 0,
        "dominance_ratio" => 0.0,
        "combined_faces" => [],
        "refresh_queue" => {
          "queued_count" => 0,
          "pending_count" => 0,
          "deferred_count" => 0,
          "failures" => []
        }
      }
    end

    def resolve_reason(checks:, queue_state:, preparation:, face_verification:, history_ready:)
      return [ "history_ready", "History build completed and identity verified." ] if history_ready

      unless ActiveModel::Type::Boolean.new.cast(checks.dig("all_posts_captured", "ready"))
        return [ "all_posts_not_yet_captured", "All posts have not been captured yet." ]
      end

      unless ActiveModel::Type::Boolean.new.cast(checks.dig("latest_50_captured", "ready"))
        code = checks.dig("latest_50_captured", "reason_code").to_s.presence || "latest_50_posts_not_captured"
        if code == "no_recent_posts_available"
          return [ "no_recent_posts_available", "No recent posts are available for history verification." ]
        end
        return [ "latest_50_posts_not_captured", "Latest 50 posts have not been fully captured yet." ]
      end

      if queue_state["downloads_queued"].to_i.positive? || queue_state["downloads_pending"].to_i.positive?
        return [ "waiting_for_media_downloads", "Waiting for media downloads to complete before verification." ]
      end

      if queue_state["analyses_queued"].to_i.positive? || queue_state["analyses_pending"].to_i.positive?
        return [ "latest_posts_not_analyzed", "Waiting for latest posts to finish analysis." ]
      end

      if queue_state["face_refresh_queued"].to_i.positive? ||
          queue_state["face_refresh_pending"].to_i.positive? ||
          queue_state["face_refresh_deferred"].to_i.positive?
        return [ "waiting_for_face_refresh", "Waiting for face refresh tasks to complete before verification." ]
      end

      unless ActiveModel::Type::Boolean.new.cast(checks.dig("latest_20_analyzed", "ready"))
        code = checks.dig("latest_20_analyzed", "reason_code").to_s.presence
        if code == "no_recent_posts_available"
          return [ "no_recent_posts_available", "No recent posts are available for history verification." ]
        end
        return [ "latest_posts_not_analyzed", "Most recent 20 posts are not fully analyzed yet." ]
      end

      unless ActiveModel::Type::Boolean.new.cast(preparation["ready_for_comment_generation"])
        code = preparation["reason_code"].to_s.presence || "profile_preparation_incomplete"
        reason = preparation["reason"].to_s.presence || "Profile preparation is incomplete."
        return [ code, reason ]
      end

      unless ActiveModel::Type::Boolean.new.cast(face_verification["confirmed"])
        code = face_verification["reason_code"].to_s.presence || "face_verification_incomplete"
        reason = face_verification["reason"].to_s.presence || "Face verification is incomplete."
        return [ code, reason ]
      end

      [ "history_build_in_progress", "History build is still in progress." ]
    end

    def build_conversation_state(ready:)
      strategy = @profile.instagram_profile_message_strategies.recent_first.first
      openers = normalize_strings(strategy&.opener_templates).first(8)

      incoming_rows = @profile.instagram_messages
        .where(direction: "incoming")
        .recent_first
        .limit(4)
        .pluck(:body, :created_at)
        .map do |body, created_at|
          {
            "body" => body.to_s.byteslice(0, 220),
            "created_at" => created_at&.iso8601
          }
        end

      has_incoming = incoming_rows.any?
      outgoing_count = @profile.instagram_messages.where(direction: "outgoing").count
      dm_allowed = @profile.dm_allowed?
      ready_bool = ActiveModel::Type::Boolean.new.cast(ready)

      {
        "can_generate_initial_message" => ready_bool && dm_allowed && !has_incoming && outgoing_count.zero?,
        "can_respond_to_existing_messages" => ready_bool && dm_allowed && has_incoming,
        "continue_natural_interaction" => ready_bool && dm_allowed,
        "dm_allowed" => dm_allowed,
        "has_incoming_messages" => has_incoming,
        "outgoing_message_count" => outgoing_count,
        "suggested_openers" => openers,
        "recent_incoming_messages" => incoming_rows
      }
    rescue StandardError
      default_conversation_state(ready: false)
    end

    def persist_and_result!(status:, ready:, reason_code:, reason:, checks:, queue_state:, preparation:, face_verification:, conversation:)
      ready_bool = ActiveModel::Type::Boolean.new.cast(ready)
      state = {
        "status" => status.to_s,
        "ready" => ready_bool,
        "reason_code" => reason_code.to_s.presence || (ready_bool ? "history_ready" : "history_build_in_progress"),
        "reason" => reason.to_s.presence || (ready_bool ? "History Ready" : "History build in progress."),
        "updated_at" => Time.current.iso8601(3),
        "checks" => checks,
        "queue" => queue_state,
        "history_analysis" => {
          "ready_for_comment_generation" => ActiveModel::Type::Boolean.new.cast(preparation["ready_for_comment_generation"]),
          "reason_code" => preparation["reason_code"].to_s.presence,
          "reason" => preparation["reason"].to_s.presence
        }.compact,
        "face_verification" => face_verification,
        "conversation" => conversation
      }

      behavior = InstagramProfileBehaviorProfile.find_or_initialize_by(instagram_profile: @profile)
      metadata = behavior.metadata.is_a?(Hash) ? behavior.metadata.deep_dup : {}
      metadata["history_build"] = state
      metadata["history_ready"] = ready_bool
      metadata["history_ready_at"] = Time.current.iso8601(3) if ready_bool
      behavior.metadata = metadata
      behavior.activity_score = behavior.activity_score.to_f
      behavior.behavioral_summary = {} unless behavior.behavioral_summary.is_a?(Hash)
      behavior.save!

      {
        status: status.to_s,
        ready: ready_bool,
        reason_code: state["reason_code"],
        reason: state["reason"],
        retryable_profile_incomplete: PROFILE_INCOMPLETE_REASON_CODES.include?(state["reason_code"].to_s),
        history_state: state
      }
    rescue StandardError
      {
        status: status.to_s,
        ready: ready_bool,
        reason_code: reason_code.to_s.presence || "history_state_persist_failed",
        reason: reason.to_s.presence || "Unable to persist history build state.",
        retryable_profile_incomplete: PROFILE_INCOMPLETE_REASON_CODES.include?(reason_code.to_s),
        history_state: {
          "status" => status.to_s,
          "ready" => ready_bool,
          "reason_code" => reason_code.to_s,
          "reason" => reason.to_s
        }
      }
    end

    def face_refresh_queue_state(face_verification:)
      raw = face_verification.is_a?(Hash) ? face_verification["refresh_queue"] : nil
      queue = raw.is_a?(Hash) ? raw : {}
      {
        queued_count: queue["queued_count"].to_i,
        pending_count: queue["pending_count"].to_i,
        deferred_count: queue["deferred_count"].to_i,
        failures: Array(queue["failures"]).first(20)
      }
    rescue StandardError
      {
        queued_count: 0,
        pending_count: 0,
        deferred_count: 0,
        failures: []
      }
    end

    def face_refresh_required?(post:)
      metadata = post.metadata.is_a?(Hash) ? post.metadata : {}
      face_recognition = metadata["face_recognition"].is_a?(Hash) ? metadata["face_recognition"] : {}
      updated_at = parse_time(face_recognition["updated_at"])
      # Do not continuously requeue on recent failed/zero-face runs; refresh on recency window.
      updated_at.nil? || updated_at < FACE_RECENCY_REFRESH_DAYS.days.ago
    rescue StandardError
      true
    end

    def face_refresh_in_flight?(post:)
      state = history_build_face_refresh_state(post: post)
      face_refresh_state_in_flight?(state)
    rescue StandardError
      false
    end

    def enqueue_face_refresh_for_post(post:)
      queued_at = Time.current
      reservation = reserve_face_refresh_slot!(post: post, queued_at: queued_at)
      return reservation unless reservation[:queued]

      job = RefreshProfilePostFaceIdentityJob.perform_later(
        instagram_account_id: @account.id,
        instagram_profile_id: @profile.id,
        instagram_profile_post_id: post.id,
        trigger_source: "profile_history_build"
      )
      mark_history_build_metadata!(
        post: post,
        attributes: {
          "face_refresh" => {
            "status" => "queued",
            "job_id" => job.job_id,
            "queue_name" => job.queue_name,
            "queued_at" => queued_at.iso8601(3),
            "requested_by" => self.class.name
          }
        }
      )

      { queued: true, job_id: job.job_id, queue_name: job.queue_name }
    rescue StandardError => e
      mark_history_build_metadata!(
        post: post,
        attributes: {
          "face_refresh" => {
            "status" => "failed",
            "failed_at" => Time.current.iso8601(3),
            "error_class" => e.class.name,
            "error_message" => e.message.to_s.byteslice(0, 220)
          }
        }
      ) if reservation&.dig(:queued)

      {
        queued: false,
        error_class: e.class.name,
        error_message: e.message.to_s
      }
    end

    def reserve_face_refresh_slot!(post:, queued_at:)
      reservation = nil

      post.with_lock do
        post.reload
        metadata = post.metadata.is_a?(Hash) ? post.metadata.deep_dup : {}
        history = metadata["history_build"].is_a?(Hash) ? metadata["history_build"].deep_dup : {}
        current_state = history["face_refresh"].is_a?(Hash) ? history["face_refresh"].deep_dup : {}

        if face_refresh_state_in_flight?(current_state)
          reservation = { queued: false, error_class: "AlreadyQueued", error_message: "Face refresh already in flight." }
          next
        end

        history["face_refresh"] = current_state.merge(
          "status" => "queued",
          "queued_at" => queued_at.iso8601(3),
          "requested_by" => self.class.name,
          "error_class" => nil,
          "error_message" => nil
        ).compact
        history["updated_at"] = queued_at.iso8601(3)
        metadata["history_build"] = history
        post.update!(metadata: metadata)
        reservation = { queued: true }
      end

      reservation || { queued: false, error_class: "UnknownReservationState", error_message: "Unable to reserve face refresh slot." }
    rescue StandardError => e
      {
        queued: false,
        error_class: e.class.name,
        error_message: e.message.to_s
      }
    end

    def face_refresh_state_in_flight?(state)
      status = state["status"].to_s
      return false unless status.in?(%w[queued running])

      reference_time = parse_time(state["started_at"]) || parse_time(state["queued_at"])
      reference_time.present? && reference_time >= FACE_REFRESH_PENDING_WINDOW_HOURS.hours.ago
    rescue StandardError
      false
    end

    def history_build_face_refresh_state(post:)
      metadata = post.metadata.is_a?(Hash) ? post.metadata : {}
      history = metadata["history_build"].is_a?(Hash) ? metadata["history_build"] : {}
      refresh = history["face_refresh"].is_a?(Hash) ? history["face_refresh"] : {}
      refresh
    rescue StandardError
      {}
    end

    def resolve_identity_for_post!(post:)
      @face_identity_resolution_service.resolve_for_post!(
        post: post,
        extracted_usernames: extracted_usernames_for_post(post),
        content_summary: post.analysis.is_a?(Hash) ? post.analysis : {}
      )
    rescue StandardError
      nil
    end

    def extracted_usernames_for_post(post)
      analysis = post.analysis.is_a?(Hash) ? post.analysis : {}
      rows = []
      rows.concat(Array(analysis["mentions"]))
      rows.concat(Array(analysis["profile_handles"]))
      rows.concat(post.caption.to_s.scan(/@[a-zA-Z0-9._]{2,30}/))
      rows.concat(analysis["ocr_text"].to_s.scan(/@[a-zA-Z0-9._]{2,30}/))
      rows.map { |value| normalize_username(value) }.reject(&:blank?).uniq.first(24)
    end

    def linked_usernames_for(person)
      meta = person&.metadata
      linked = meta.is_a?(Hash) ? meta["linked_usernames"] : nil
      normalize_strings(linked).map { |value| normalize_username(value) }.reject(&:blank?).uniq
    end

    def normalize_strings(value)
      Array(value).map { |row| row.to_s.strip }.reject(&:blank?)
    end

    def mark_history_build_metadata!(post:, attributes:)
      post.with_lock do
        metadata = post.metadata.is_a?(Hash) ? post.metadata.deep_dup : {}
        state = metadata["history_build"].is_a?(Hash) ? metadata["history_build"].deep_dup : {}
        state.merge!(attributes.to_h)
        state["updated_at"] = Time.current.iso8601(3)
        metadata["history_build"] = state
        post.update!(metadata: metadata)
      end
    rescue StandardError
      nil
    end

    def post_analyzed?(post)
      post.ai_status.to_s == "analyzed" && post.analyzed_at.present?
    end

    def post_analysis_in_flight?(post)
      return true if post.ai_status.to_s.in?(%w[pending running])

      metadata = post.metadata.is_a?(Hash) ? post.metadata : {}
      pipeline = metadata["ai_pipeline"].is_a?(Hash) ? metadata["ai_pipeline"] : {}
      pipeline["status"].to_s == "running"
    rescue StandardError
      false
    end

    def media_download_in_flight?(post)
      metadata = post.metadata.is_a?(Hash) ? post.metadata : {}
      status = metadata["download_status"].to_s
      queued_at = parse_time(metadata["download_queued_at"])
      status == "queued" && queued_at.present? && queued_at > 8.hours.ago
    rescue StandardError
      false
    end

    def downloadable_post?(post)
      return false if deleted_post?(post)
      return true if post.source_media_url.to_s.strip.present?

      metadata = post.metadata.is_a?(Hash) ? post.metadata : {}
      metadata["media_url_video"].to_s.strip.present? || metadata["media_url_image"].to_s.strip.present?
    end

    def deleted_post?(post)
      metadata = post.metadata.is_a?(Hash) ? post.metadata : {}
      ActiveModel::Type::Boolean.new.cast(metadata["deleted_from_source"])
    end

    def active_posts_scope
      @profile.instagram_profile_posts.where("COALESCE(metadata ->> 'deleted_from_source', 'false') <> 'true'")
    end

    def normalize_username(value)
      text = value.to_s.strip.downcase
      text = text.delete_prefix("@")
      text.presence
    end

    def parse_time(value)
      return nil if value.to_s.blank?

      Time.zone.parse(value.to_s)
    rescue StandardError
      nil
    end

    def default_checks
      {
        "all_posts_captured" => {
          "ready" => false,
          "reason_code" => "not_started"
        },
        "latest_50_captured" => {
          "ready" => false,
          "reason_code" => "not_started"
        },
        "latest_20_analyzed" => {
          "ready" => false,
          "reason_code" => "not_started"
        }
      }
    end

    def default_queue_state
      {
        "downloads_queued" => 0,
        "downloads_pending" => 0,
        "downloads_skipped" => 0,
        "analysis_failures" => [],
        "analyses_queued" => 0,
        "analyses_pending" => 0,
        "analyses_skipped" => 0,
        "analysis_queue_failures" => [],
        "face_refresh_queued" => 0,
        "face_refresh_pending" => 0,
        "face_refresh_deferred" => 0,
        "face_refresh_failures" => []
      }
    end

    def default_face_verification
      {
        "confirmed" => false,
        "reason_code" => "not_started",
        "reason" => "Face verification has not started.",
        "total_faces" => 0,
        "reference_face_count" => 0,
        "dominance_ratio" => 0.0,
        "combined_faces" => [],
        "refresh_queue" => {
          "queued_count" => 0,
          "pending_count" => 0,
          "deferred_count" => 0,
          "failures" => []
        }
      }
    end

    def default_conversation_state(ready:)
      {
        "can_generate_initial_message" => false,
        "can_respond_to_existing_messages" => false,
        "continue_natural_interaction" => ActiveModel::Type::Boolean.new.cast(ready),
        "dm_allowed" => false,
        "has_incoming_messages" => false,
        "outgoing_message_count" => 0,
        "suggested_openers" => [],
        "recent_incoming_messages" => []
      }
    end

    class ExistingPostsCollector
      def initialize(posts:)
        @posts = posts
      end

      def collect_and_persist!(**_kwargs)
        { posts: Array(@posts) }
      end
    end
  end
end
