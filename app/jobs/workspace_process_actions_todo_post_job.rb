class WorkspaceProcessActionsTodoPostJob < ApplicationJob
  queue_as :ai

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

  PROFILE_RETRY_MAX_ATTEMPTS = ENV.fetch("WORKSPACE_ACTIONS_PROFILE_RETRY_MAX_ATTEMPTS", 4).to_i.clamp(1, 12)
  POST_RETRY_WAIT_MINUTES = ENV.fetch("WORKSPACE_ACTIONS_POST_RETRY_WAIT_MINUTES", 20).to_i.clamp(5, 180)
  MEDIA_RETRY_WAIT_MINUTES = ENV.fetch("WORKSPACE_ACTIONS_MEDIA_RETRY_WAIT_MINUTES", 10).to_i.clamp(2, 90)
  ENQUEUE_COOLDOWN_SECONDS = ENV.fetch("WORKSPACE_ACTIONS_ENQUEUE_COOLDOWN_SECONDS", 180).to_i.clamp(15, 1800)
  RUNNING_LOCK_SECONDS = ENV.fetch("WORKSPACE_ACTIONS_RUNNING_LOCK_SECONDS", 600).to_i.clamp(60, 3600)

  def self.enqueue_if_needed!(account:, profile:, post:, requested_by:, wait_until: nil, force: false)
    return { enqueued: false, reason: "post_missing" } unless account && profile && post

    now = Time.current
    forced = ActiveModel::Type::Boolean.new.cast(force)
    scheduled_at = wait_until.is_a?(Time) ? wait_until : nil

    # Persisted queue state is row-local; lock to prevent duplicate enqueue races.
    post.with_lock do
      metadata = post.metadata.is_a?(Hash) ? post.metadata.deep_dup : {}
      state = metadata["workspace_actions"].is_a?(Hash) ? metadata["workspace_actions"].deep_dup : {}
      suggestions = normalized_suggestions(post)
      return { enqueued: false, reason: "already_ready" } if suggestions.any? && !forced

      next_run_at = parse_time(state["next_run_at"])
      if next_run_at.present? && next_run_at > now && !forced && scheduled_at.nil?
        return { enqueued: false, reason: "retry_already_scheduled", next_run_at: next_run_at.iso8601 }
      end

      lock_until = parse_time(state["lock_until"])
      if lock_until.present? && lock_until > now && !forced
        return { enqueued: false, reason: "already_running", lock_until: lock_until.iso8601 }
      end

      last_enqueued_at = parse_time(state["last_enqueued_at"])
      if last_enqueued_at.present? && (now - last_enqueued_at) < ENQUEUE_COOLDOWN_SECONDS && !forced && scheduled_at.nil?
        return { enqueued: false, reason: "enqueue_cooldown_active" }
      end

      job =
        if scheduled_at.present?
          set(wait_until: scheduled_at).perform_later(
            instagram_account_id: account.id,
            instagram_profile_id: profile.id,
            instagram_profile_post_id: post.id,
            requested_by: requested_by.to_s
          )
        else
          perform_later(
            instagram_account_id: account.id,
            instagram_profile_id: profile.id,
            instagram_profile_post_id: post.id,
            requested_by: requested_by.to_s
          )
        end

      state["status"] = "queued"
      state["requested_by"] = requested_by.to_s.presence || "workspace"
      state["job_id"] = job.job_id
      state["queue_name"] = job.queue_name
      state["last_enqueued_at"] = now.iso8601(3)
      state["last_error"] = nil
      state["next_run_at"] = scheduled_at&.iso8601(3)
      state["updated_at"] = now.iso8601(3)
      state["source"] = name
      metadata["workspace_actions"] = state

      post.update!(metadata: metadata)

      {
        enqueued: true,
        reason: scheduled_at.present? ? "scheduled" : "queued",
        job_id: job.job_id,
        queue_name: job.queue_name,
        next_run_at: scheduled_at&.iso8601(3)
      }
    end
  rescue StandardError => e
    {
      enqueued: false,
      reason: "enqueue_failed",
      error_class: e.class.name,
      error_message: e.message.to_s
    }
  end

  def perform(instagram_account_id:, instagram_profile_id:, instagram_profile_post_id:, requested_by: "workspace")
    account = InstagramAccount.find(instagram_account_id)
    profile = account.instagram_profiles.find(instagram_profile_id)
    post = profile.instagram_profile_posts.find(instagram_profile_post_id)

    unless user_created_post?(post)
      persist_workspace_state!(post: post, status: "skipped_non_user_post", requested_by: requested_by, next_run_at: nil)
      return
    end

    policy_decision = Instagram::ProfileScanPolicy.new(profile: profile).decision
    if ActiveModel::Type::Boolean.new.cast(policy_decision[:skip_post_analysis])
      persist_workspace_state!(
        post: post,
        status: "skipped_page_profile",
        requested_by: requested_by,
        last_error: policy_decision[:reason].to_s,
        next_run_at: nil
      )
      return
    end

    if post_deleted_from_source?(post)
      persist_workspace_state!(post: post, status: "skipped_deleted_source", requested_by: requested_by, next_run_at: nil)
      return
    end

    mark_running!(post: post, requested_by: requested_by)
    ensure_video_preview_generation!(post: post)

    unless post.media.attached?
      queue_media_download!(account: account, profile: profile, post: post)
      schedule_retry!(
        account: account,
        profile: profile,
        post: post,
        requested_by: requested_by,
        wait_until: Time.current + MEDIA_RETRY_WAIT_MINUTES.minutes,
        status: "waiting_media_download",
        last_error: nil
      )
      return
    end

    if post_analysis_running?(post)
      schedule_retry!(
        account: account,
        profile: profile,
        post: post,
        requested_by: requested_by,
        wait_until: Time.current + POST_RETRY_WAIT_MINUTES.minutes,
        status: "waiting_post_analysis",
        last_error: nil
      )
      return
    end

    unless post_analyzed?(post)
      queue_post_analysis!(account: account, profile: profile, post: post)
      schedule_retry!(
        account: account,
        profile: profile,
        post: post,
        requested_by: requested_by,
        wait_until: Time.current + POST_RETRY_WAIT_MINUTES.minutes,
        status: "waiting_post_analysis",
        last_error: nil
      )
      return
    end

    suggestions = self.class.normalized_suggestions(post)
    if suggestions.any?
      persist_workspace_state!(
        post: post,
        status: "ready",
        requested_by: requested_by,
        suggestions_count: suggestions.length,
        next_run_at: nil
      )
      return
    end

    comment_result = Ai::PostCommentGenerationService.new(
      account: account,
      profile: profile,
      post: post,
      enforce_required_evidence: true
    ).run!

    post.reload
    history_retry_result = nil
    if history_build_retry_needed_for_comment_generation?(post: post)
      history_retry_result = schedule_build_history_retry!(
        account: account,
        profile: profile,
        post: post,
        requested_by: requested_by,
        history_reason_code: post.metadata.dig("comment_generation_policy", "history_reason_code").to_s
      )
    end

    suggestions = self.class.normalized_suggestions(post)
    if suggestions.any?
      persist_workspace_state!(
        post: post,
        status: "ready",
        requested_by: requested_by,
        suggestions_count: suggestions.length,
        next_run_at: nil
      )
      return
    end

    if history_build_retry_needed_for_comment_generation?(post: post)
      retry_result = history_retry_result || {
        queued: false,
        reason: "build_history_retry_not_triggered"
      }
      persist_workspace_state!(
        post: post,
        status: "waiting_build_history",
        requested_by: requested_by,
        next_run_at: parse_time(retry_result[:next_run_at]),
        last_error: retry_result[:queued] ? nil : retry_result[:reason].to_s
      )
      return
    end

    blocked_reason = post.metadata.dig("comment_generation_policy", "blocked_reason").to_s
    reason_code = post.metadata.dig("comment_generation_policy", "blocked_reason_code").to_s
    persist_workspace_state!(
      post: post,
      status: "failed",
      requested_by: requested_by,
      next_run_at: nil,
      last_error: blocked_reason.presence || reason_code.presence || "comment_generation_failed"
    )
  rescue StandardError => e
    post&.reload
    persist_workspace_state!(
      post: post,
      status: "failed",
      requested_by: requested_by,
      next_run_at: nil,
      last_error: "#{e.class}: #{e.message}"
    ) if post&.persisted?
    raise
  end

  private

  def self.parse_time(value)
    return nil if value.to_s.blank?

    Time.zone.parse(value.to_s)
  rescue StandardError
    nil
  end

  def parse_time(value)
    self.class.parse_time(value)
  end

  def self.normalized_suggestions(post)
    analysis = post.analysis.is_a?(Hash) ? post.analysis : {}
    Array(analysis["comment_suggestions"]).map { |value| value.to_s.strip }.reject(&:blank?).uniq.first(8)
  rescue StandardError
    []
  end

  def persist_workspace_state!(post:, status:, requested_by:, next_run_at:, last_error: nil, suggestions_count: nil)
    post.with_lock do
      metadata = post.metadata.is_a?(Hash) ? post.metadata.deep_dup : {}
      state = metadata["workspace_actions"].is_a?(Hash) ? metadata["workspace_actions"].deep_dup : {}

      state["status"] = status.to_s
      state["requested_by"] = requested_by.to_s.presence || state["requested_by"].to_s.presence || "workspace"
      state["updated_at"] = Time.current.iso8601(3)
      state["finished_at"] = Time.current.iso8601(3)
      state["lock_until"] = nil
      state["last_error"] = last_error.to_s.presence
      state["next_run_at"] = next_run_at&.iso8601(3)
      state["suggestions_count"] = suggestions_count.to_i if suggestions_count.present?
      state["last_ready_at"] = Time.current.iso8601(3) if status.to_s == "ready"

      metadata["workspace_actions"] = state
      post.update!(metadata: metadata)
    end
  rescue StandardError
    nil
  end

  def mark_running!(post:, requested_by:)
    post.with_lock do
      metadata = post.metadata.is_a?(Hash) ? post.metadata.deep_dup : {}
      state = metadata["workspace_actions"].is_a?(Hash) ? metadata["workspace_actions"].deep_dup : {}
      now = Time.current

      state["status"] = "running"
      state["requested_by"] = requested_by.to_s.presence || "workspace"
      state["started_at"] = now.iso8601(3)
      state["updated_at"] = now.iso8601(3)
      state["lock_until"] = (now + RUNNING_LOCK_SECONDS.seconds).iso8601(3)
      state["last_error"] = nil

      metadata["workspace_actions"] = state
      post.update!(metadata: metadata)
    end
  end

  def schedule_retry!(account:, profile:, post:, requested_by:, wait_until:, status:, last_error:)
    retry_time = wait_until.is_a?(Time) ? wait_until : Time.current + POST_RETRY_WAIT_MINUTES.minutes
    result = self.class.enqueue_if_needed!(
      account: account,
      profile: profile,
      post: post,
      requested_by: "workspace_retry:#{requested_by}",
      wait_until: retry_time,
      force: true
    )

    persist_workspace_state!(
      post: post,
      status: status,
      requested_by: requested_by,
      next_run_at: retry_time,
      last_error: result[:enqueued] ? nil : (last_error.presence || result[:reason].to_s)
    )

    result
  end

  def queue_media_download!(account:, profile:, post:)
    metadata = post.metadata.is_a?(Hash) ? post.metadata : {}
    workspace = metadata["workspace_actions"].is_a?(Hash) ? metadata["workspace_actions"] : {}
    pending_job = workspace["media_download_job_id"].to_s

    if pending_job.present? && post.media.attached?
      return { queued: false, reason: "already_downloaded" }
    end

    job = DownloadInstagramProfilePostMediaJob.perform_later(
      instagram_account_id: account.id,
      instagram_profile_id: profile.id,
      instagram_profile_post_id: post.id,
      trigger_analysis: false
    )

    post.with_lock do
      updated_metadata = post.metadata.is_a?(Hash) ? post.metadata.deep_dup : {}
      state = updated_metadata["workspace_actions"].is_a?(Hash) ? updated_metadata["workspace_actions"].deep_dup : {}
      state["media_download_job_id"] = job.job_id
      state["media_download_queued_at"] = Time.current.iso8601(3)
      updated_metadata["workspace_actions"] = state
      post.update!(metadata: updated_metadata)
    end

    { queued: true, job_id: job.job_id }
  rescue StandardError => e
    { queued: false, reason: "media_download_enqueue_failed", error_class: e.class.name, error_message: e.message.to_s }
  end

  def queue_post_analysis!(account:, profile:, post:)
    metadata = post.metadata.is_a?(Hash) ? post.metadata : {}
    workspace = metadata["workspace_actions"].is_a?(Hash) ? metadata["workspace_actions"] : {}
    last_queued_at = parse_time(workspace["post_analysis_queued_at"])
    if last_queued_at.present? && last_queued_at > 10.minutes.ago && post_analysis_running?(post)
      return { queued: false, reason: "post_analysis_already_running" }
    end

    job = AnalyzeInstagramProfilePostJob.perform_later(
      instagram_account_id: account.id,
      instagram_profile_id: profile.id,
      instagram_profile_post_id: post.id,
      task_flags: {
        analyze_visual: true,
        analyze_faces: true,
        run_ocr: true,
        run_video: true,
        run_metadata: true,
        generate_comments: false,
        enforce_comment_evidence_policy: false,
        retry_on_incomplete_profile: false
      }
    )

    post.with_lock do
      updated_metadata = post.metadata.is_a?(Hash) ? post.metadata.deep_dup : {}
      state = updated_metadata["workspace_actions"].is_a?(Hash) ? updated_metadata["workspace_actions"].deep_dup : {}
      state["post_analysis_job_id"] = job.job_id
      state["post_analysis_queued_at"] = Time.current.iso8601(3)
      updated_metadata["workspace_actions"] = state
      post.update!(metadata: updated_metadata)
    end

    { queued: true, job_id: job.job_id }
  rescue StandardError => e
    { queued: false, reason: "post_analysis_enqueue_failed", error_class: e.class.name, error_message: e.message.to_s }
  end

  def schedule_build_history_retry!(account:, profile:, post:, requested_by:, history_reason_code:)
    post.with_lock do
      metadata = post.metadata.is_a?(Hash) ? post.metadata.deep_dup : {}
      state = metadata["workspace_actions"].is_a?(Hash) ? metadata["workspace_actions"].deep_dup : {}
      attempts = state["profile_retry_attempts"].to_i
      if attempts >= PROFILE_RETRY_MAX_ATTEMPTS
        next {
          queued: false,
          reason: "retry_attempts_exhausted",
          next_run_at: nil
        }
      end

      resume_result = BuildInstagramProfileHistoryJob.enqueue_with_resume_if_needed!(
        account: account,
        profile: profile,
        trigger_source: "workspace_actions_queue",
        requested_by: self.class.name,
        resume_job: {
          job_class: self.class,
          job_kwargs: {
            instagram_account_id: account.id,
            instagram_profile_id: profile.id,
            instagram_profile_post_id: post.id,
            requested_by: "workspace_history_retry:#{requested_by}"
          }
        }
      )
      unless ActiveModel::Type::Boolean.new.cast(resume_result[:accepted])
        next {
          queued: false,
          reason: resume_result[:reason].to_s.presence || "build_history_enqueue_failed",
          next_run_at: nil
        }
      end

      state["profile_retry_attempts"] = attempts + 1
      state["profile_retry_reason_code"] = history_reason_code.to_s
      state["build_history_action_log_id"] = resume_result[:action_log_id].to_i if resume_result[:action_log_id].present?
      state["build_history_job_id"] = resume_result[:job_id].to_s.presence
      state["next_run_at"] = resume_result[:next_run_at].to_s.presence
      state["updated_at"] = Time.current.iso8601(3)
      metadata["workspace_actions"] = state
      post.update!(metadata: metadata)

      {
        queued: true,
        reason: "build_history_fallback_registered",
        next_run_at: resume_result[:next_run_at],
        action_log_id: resume_result[:action_log_id],
        job_id: resume_result[:job_id].to_s
      }
    end
  rescue StandardError => e
    {
      queued: false,
      reason: "retry_enqueue_failed",
      next_run_at: nil,
      error_class: e.class.name,
      error_message: e.message.to_s
    }
  end

  def history_build_retry_needed_for_comment_generation?(post:)
    policy = post.metadata.is_a?(Hash) ? post.metadata["comment_generation_policy"] : nil
    return false unless policy.is_a?(Hash)
    return false if ActiveModel::Type::Boolean.new.cast(policy["history_ready"])

    PROFILE_INCOMPLETE_REASON_CODES.include?(policy["history_reason_code"].to_s)
  rescue StandardError
    false
  end

  def post_analysis_running?(post)
    return true if post.ai_status.to_s.in?(%w[pending running])

    metadata = post.metadata.is_a?(Hash) ? post.metadata : {}
    pipeline = metadata["ai_pipeline"].is_a?(Hash) ? metadata["ai_pipeline"] : {}
    pipeline["status"].to_s == "running"
  rescue StandardError
    false
  end

  def post_analyzed?(post)
    post.ai_status.to_s == "analyzed" && post.analyzed_at.present?
  end

  def post_deleted_from_source?(post)
    metadata = post.metadata.is_a?(Hash) ? post.metadata : {}
    ActiveModel::Type::Boolean.new.cast(metadata["deleted_from_source"])
  end

  def user_created_post?(post)
    metadata = post.metadata.is_a?(Hash) ? post.metadata : {}
    post_kind = metadata["post_kind"].to_s.downcase
    return false if post_kind == "story"

    product_type = metadata["product_type"].to_s.downcase
    return false if product_type == "story"

    return false if ActiveModel::Type::Boolean.new.cast(metadata["is_story"])

    true
  rescue StandardError
    false
  end

  def ensure_video_preview_generation!(post:)
    return unless post.media.attached?
    return unless post.media.blob&.content_type.to_s.start_with?("video/")
    return if post.preview_image.attached?

    cache_key = "workspace_actions:preview:#{post.id}"
    Rails.cache.fetch(cache_key, expires_in: 30.minutes) do
      GenerateProfilePostPreviewImageJob.perform_later(instagram_profile_post_id: post.id)
      true
    end
  rescue StandardError
    nil
  end
end
