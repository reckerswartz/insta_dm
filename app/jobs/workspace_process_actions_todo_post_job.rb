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
  MEDIA_RETRY_MAX_ATTEMPTS = ENV.fetch("WORKSPACE_ACTIONS_MEDIA_RETRY_MAX_ATTEMPTS", 6).to_i.clamp(1, 20)
  POST_ANALYSIS_RETRY_MAX_ATTEMPTS = ENV.fetch("WORKSPACE_ACTIONS_POST_RETRY_MAX_ATTEMPTS", 8).to_i.clamp(1, 25)
  COMMENT_GENERATION_RETRY_MAX_ATTEMPTS = ENV.fetch("WORKSPACE_ACTIONS_COMMENT_RETRY_MAX_ATTEMPTS", 8).to_i.clamp(1, 25)
  POST_RETRY_WAIT_MINUTES = ENV.fetch("WORKSPACE_ACTIONS_POST_RETRY_WAIT_MINUTES", 20).to_i.clamp(5, 180)
  MEDIA_RETRY_WAIT_MINUTES = ENV.fetch("WORKSPACE_ACTIONS_MEDIA_RETRY_WAIT_MINUTES", 10).to_i.clamp(2, 90)
  COMMENT_RETRY_WAIT_MINUTES = ENV.fetch("WORKSPACE_ACTIONS_COMMENT_RETRY_WAIT_MINUTES", 5).to_i.clamp(1, 90)
  RETRY_BACKOFF_MAX_WAIT_MINUTES = ENV.fetch("WORKSPACE_ACTIONS_RETRY_BACKOFF_MAX_WAIT_MINUTES", 240).to_i.clamp(15, 1440)
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
    account = self.class.safe_find_record(InstagramAccount, instagram_account_id, {
      job_class: self.class.name,
      instagram_profile_id: instagram_profile_id,
      instagram_profile_post_id: instagram_profile_post_id
    })
    return unless account

    profile = self.class.safe_find_chain(account, :instagram_profiles, instagram_profile_id, {
      job_class: self.class.name,
      instagram_account_id: instagram_account_id,
      instagram_profile_post_id: instagram_profile_post_id
    })
    return unless profile

    post = self.class.safe_find_chain(profile, :instagram_profile_posts, instagram_profile_post_id, {
      job_class: self.class.name,
      instagram_account_id: instagram_account_id,
      instagram_profile_id: instagram_profile_id
    })
    return unless post

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

    policy = comment_generation_policy(post: post)
    if history_build_retry_needed_for_comment_generation?(post: post)
      retry_state = policy_retry_state_from_policy(policy)
      history_retry_result = nil
      if retry_state[:next_run_at].blank?
        history_retry_result = schedule_build_history_retry!(
          account: account,
          profile: profile,
          post: post,
          requested_by: requested_by,
          history_reason_code: policy["history_reason_code"].to_s
        )
      end

      next_run_at = retry_state[:next_run_at] || parse_time(history_retry_result&.dig(:next_run_at))
      retry_reason = retry_state[:reason].presence || history_retry_result&.dig(:reason).to_s
      persist_workspace_state!(
        post: post,
        status: "waiting_build_history",
        requested_by: requested_by,
        next_run_at: next_run_at,
        last_error: retry_reason.to_s == "build_history_fallback_registered" ? nil : retry_reason.presence
      )
      return
    end

    if comment_generation_terminal_blocked?(post: post, policy: policy)
      blocked_reason = policy["blocked_reason"].to_s
      reason_code = policy["blocked_reason_code"].to_s
      persist_workspace_state!(
        post: post,
        status: "failed",
        requested_by: requested_by,
        next_run_at: nil,
        last_error: blocked_reason.presence || reason_code.presence || "comment_generation_failed"
      )
      return
    end

    enqueue_result =
      if comment_generation_running?(post: post)
        { queued: false, reason: "comment_generation_already_running" }
      else
        queue_comment_generation!(account: account, profile: profile, post: post)
      end

    schedule_retry!(
      account: account,
      profile: profile,
      post: post,
      requested_by: requested_by,
      wait_until: Time.current + COMMENT_RETRY_WAIT_MINUTES.minutes,
      status: "waiting_comment_generation",
      last_error: enqueue_result[:queued] ? nil : enqueue_result[:reason].to_s
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

  def comment_generation_policy(post:)
    metadata = post.metadata.is_a?(Hash) ? post.metadata : {}
    policy = metadata["comment_generation_policy"]
    policy.is_a?(Hash) ? policy : {}
  rescue StandardError
    {}
  end

  def policy_retry_state_from_policy(policy)
    row = policy.is_a?(Hash) ? policy["retry_state"] : nil
    row = {} unless row.is_a?(Hash)
    {
      next_run_at: parse_time(row["next_run_at"]),
      reason: row["last_reason_code"].to_s
    }
  rescue StandardError
    { next_run_at: nil, reason: nil }
  end

  def comment_generation_terminal_blocked?(post:, policy:)
    return false unless policy.is_a?(Hash)
    return false unless policy["status"].to_s == "blocked"

    history_reason = policy["history_reason_code"].to_s
    return false if PROFILE_INCOMPLETE_REASON_CODES.include?(history_reason)

    self.class.normalized_suggestions(post).empty?
  rescue StandardError
    false
  end

  def comment_generation_running?(post:)
    metadata = post.metadata.is_a?(Hash) ? post.metadata : {}
    state = metadata["workspace_actions"].is_a?(Hash) ? metadata["workspace_actions"] : {}
    queued_at = parse_time(state["comment_generation_queued_at"])
    job_id = state["comment_generation_job_id"].to_s

    job_id.present? && queued_at.present? && queued_at > 45.minutes.ago
  rescue StandardError
    false
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
      if terminal_workspace_status?(status)
        state["media_download_retry_attempts"] = 0
        state["post_analysis_retry_attempts"] = 0
        state["comment_generation_retry_attempts"] = 0
        state["retry_exhausted"] = false
      end

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
      state["retry_exhausted"] = false

      metadata["workspace_actions"] = state
      post.update!(metadata: metadata)
    end
  end

  def schedule_retry!(account:, profile:, post:, requested_by:, wait_until:, status:, last_error:)
    retry_policy = retry_policy_for_status(status)
    retry_time = wait_until.is_a?(Time) ? wait_until : Time.current + POST_RETRY_WAIT_MINUTES.minutes

    if retry_policy
      retry_state = register_retry_attempt!(post: post, policy: retry_policy)
      if retry_state[:exhausted]
        reason = "#{status}_retry_attempts_exhausted"
        persist_workspace_state!(
          post: post,
          status: "failed",
          requested_by: requested_by,
          next_run_at: nil,
          last_error: reason
        )
        return { enqueued: false, reason: reason, exhausted: true }
      end

      retry_time = retry_state[:retry_time] if retry_state[:retry_time].is_a?(Time)
    end

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

  def queue_comment_generation!(account:, profile:, post:)
    job = GeneratePostCommentSuggestionsJob.perform_later(
      instagram_account_id: account.id,
      instagram_profile_id: profile.id,
      instagram_profile_post_id: post.id,
      enforce_comment_evidence_policy: true,
      retry_on_incomplete_profile: true,
      source_step: "workspace_actions"
    )

    post.with_lock do
      updated_metadata = post.metadata.is_a?(Hash) ? post.metadata.deep_dup : {}
      state = updated_metadata["workspace_actions"].is_a?(Hash) ? updated_metadata["workspace_actions"].deep_dup : {}
      state["comment_generation_job_id"] = job.job_id
      state["comment_generation_queue_name"] = job.queue_name
      state["comment_generation_queued_at"] = Time.current.iso8601(3)
      updated_metadata["workspace_actions"] = state
      post.update!(metadata: updated_metadata)
    end

    { queued: true, job_id: job.job_id }
  rescue StandardError => e
    { queued: false, reason: "comment_generation_enqueue_failed", error_class: e.class.name, error_message: e.message.to_s }
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

  def retry_policy_for_status(status)
    case status.to_s
    when "waiting_media_download"
      {
        attempt_key: "media_download_retry_attempts",
        max_attempts: MEDIA_RETRY_MAX_ATTEMPTS,
        base_wait_minutes: MEDIA_RETRY_WAIT_MINUTES
      }
    when "waiting_post_analysis"
      {
        attempt_key: "post_analysis_retry_attempts",
        max_attempts: POST_ANALYSIS_RETRY_MAX_ATTEMPTS,
        base_wait_minutes: POST_RETRY_WAIT_MINUTES
      }
    when "waiting_comment_generation"
      {
        attempt_key: "comment_generation_retry_attempts",
        max_attempts: COMMENT_GENERATION_RETRY_MAX_ATTEMPTS,
        base_wait_minutes: COMMENT_RETRY_WAIT_MINUTES
      }
    else
      nil
    end
  end

  def register_retry_attempt!(post:, policy:)
    post.with_lock do
      metadata = post.metadata.is_a?(Hash) ? post.metadata.deep_dup : {}
      state = metadata["workspace_actions"].is_a?(Hash) ? metadata["workspace_actions"].deep_dup : {}
      key = policy[:attempt_key].to_s
      attempts = state[key].to_i + 1
      max_attempts = policy[:max_attempts].to_i

      if attempts > max_attempts
        state["retry_exhausted"] = true
        state["updated_at"] = Time.current.iso8601(3)
        metadata["workspace_actions"] = state
        post.update!(metadata: metadata)
        return { exhausted: true, attempts: attempts - 1 }
      end

      wait_minutes = [ policy[:base_wait_minutes].to_i * (2 ** (attempts - 1)), RETRY_BACKOFF_MAX_WAIT_MINUTES ].min
      retry_time = Time.current + wait_minutes.minutes

      state[key] = attempts
      state["retry_exhausted"] = false
      state["updated_at"] = Time.current.iso8601(3)
      metadata["workspace_actions"] = state
      post.update!(metadata: metadata)

      { exhausted: false, attempts: attempts, wait_minutes: wait_minutes, retry_time: retry_time }
    end
  rescue StandardError => e
    { exhausted: false, error_class: e.class.name, error_message: e.message.to_s }
  end

  def terminal_workspace_status?(status)
    text = status.to_s
    return true if text == "ready"
    return true if text == "failed"
    return true if text.start_with?("skipped_")

    false
  end
end
