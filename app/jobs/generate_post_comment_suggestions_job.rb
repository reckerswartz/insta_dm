class GeneratePostCommentSuggestionsJob < ApplicationJob
  queue_as :ai_metadata_queue

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
  COMMENT_RETRY_MAX_ATTEMPTS = ENV.fetch("POST_COMMENT_RETRY_MAX_ATTEMPTS", 3).to_i.clamp(1, 10)

  def perform(
    instagram_account_id:,
    instagram_profile_id:,
    instagram_profile_post_id:,
    enforce_comment_evidence_policy: true,
    retry_on_incomplete_profile: true,
    source_step: "metadata"
  )
    account = InstagramAccount.find_by(id: instagram_account_id)
    return unless account

    profile = account.instagram_profiles.find_by(id: instagram_profile_id)
    return unless profile

    post = profile.instagram_profile_posts.find_by(id: instagram_profile_post_id)
    return unless post

    comment_result = Ai::PostCommentGenerationService.new(
      account: account,
      profile: profile,
      post: post,
      enforce_required_evidence: ActiveModel::Type::Boolean.new.cast(enforce_comment_evidence_policy)
    ).run!

    retry_result =
      if ActiveModel::Type::Boolean.new.cast(retry_on_incomplete_profile)
        enqueue_comment_retry_if_needed!(
          account: account,
          profile: profile,
          post: post
        )
      else
        { queued: false, reason: "retry_disabled" }
      end

    Ops::StructuredLogger.info(
      event: "post_comment_generation.completed",
      payload: {
        active_job_id: job_id,
        instagram_account_id: account.id,
        instagram_profile_id: profile.id,
        instagram_profile_post_id: post.id,
        source_step: source_step.to_s,
        comment_generation_status: comment_result[:status].to_s,
        comment_generation_blocked: ActiveModel::Type::Boolean.new.cast(comment_result[:blocked]),
        comment_suggestions_count: comment_result[:suggestions_count].to_i,
        comment_reason_code: comment_result[:reason_code].to_s.presence,
        comment_retry_queued: ActiveModel::Type::Boolean.new.cast(retry_result[:queued]),
        comment_retry_reason: retry_result[:reason].to_s.presence,
        comment_retry_job_id: retry_result[:job_id].to_s.presence
      }
    )
  end

  private

  def enqueue_comment_retry_if_needed!(account:, profile:, post:)
    metadata = post.metadata.is_a?(Hash) ? post.metadata.deep_dup : {}
    policy = metadata["comment_generation_policy"]
    return { queued: false, reason: "policy_missing" } unless policy.is_a?(Hash)
    return { queued: false, reason: "history_ready" } if ActiveModel::Type::Boolean.new.cast(policy["history_ready"])

    history_reason_code = policy["history_reason_code"].to_s
    return { queued: false, reason: "history_reason_not_retryable" } unless PROFILE_INCOMPLETE_REASON_CODES.include?(history_reason_code)

    retry_state = policy["retry_state"].is_a?(Hash) ? policy["retry_state"].deep_dup : {}
    attempts = retry_state["attempts"].to_i
    return { queued: false, reason: "retry_attempts_exhausted" } if attempts >= COMMENT_RETRY_MAX_ATTEMPTS

    build_history_result = BuildInstagramProfileHistoryJob.enqueue_with_resume_if_needed!(
      account: account,
      profile: profile,
      trigger_source: "post_metadata_comment_fallback",
      requested_by: self.class.name,
      resume_job: {
        job_class: AnalyzeInstagramProfilePostJob,
        job_kwargs: {
          instagram_account_id: account.id,
          instagram_profile_id: profile.id,
          instagram_profile_post_id: post.id,
          pipeline_mode: "inline",
          task_flags: {
            analyze_visual: false,
            analyze_faces: false,
            run_ocr: false,
            run_video: false,
            run_metadata: true,
            generate_comments: true,
            enforce_comment_evidence_policy: true,
            retry_on_incomplete_profile: true
          }
        }
      }
    )
    return { queued: false, reason: build_history_result[:reason] } unless ActiveModel::Type::Boolean.new.cast(build_history_result[:accepted])

    retry_state["attempts"] = attempts + 1
    retry_state["last_reason_code"] = history_reason_code
    retry_state["last_blocked_at"] = Time.current.iso8601(3)
    retry_state["last_enqueued_at"] = Time.current.iso8601(3)
    retry_state["next_run_at"] = build_history_result[:next_run_at].to_s.presence
    retry_state["job_id"] = build_history_result[:job_id].to_s.presence
    retry_state["build_history_action_log_id"] = build_history_result[:action_log_id].to_i if build_history_result[:action_log_id].present?
    retry_state["source"] = self.class.name
    retry_state["mode"] = "build_history_fallback"

    policy["retry_state"] = retry_state
    policy["updated_at"] = Time.current.iso8601(3)
    metadata["comment_generation_policy"] = policy
    post.update!(metadata: metadata)

    {
      queued: true,
      reason: "build_history_fallback_registered",
      job_id: build_history_result[:job_id].to_s,
      action_log_id: build_history_result[:action_log_id],
      next_run_at: build_history_result[:next_run_at].to_s
    }
  rescue StandardError => e
    {
      queued: false,
      reason: "retry_enqueue_failed",
      error_class: e.class.name,
      error_message: e.message.to_s
    }
  end
end
