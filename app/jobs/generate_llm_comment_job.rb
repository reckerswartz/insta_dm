class GenerateLlmCommentJob < ApplicationJob
  queue_as :ai

  PROFILE_PREPARATION_RETRY_REASON_CODES = %w[
    latest_posts_not_analyzed
    insufficient_analyzed_posts
    no_recent_posts_available
    missing_structured_post_signals
    profile_preparation_failed
    profile_preparation_error
  ].freeze
  PROFILE_PREPARATION_RETRY_WAIT_HOURS = ENV.fetch("STORY_COMMENT_PROFILE_PREPARATION_RETRY_HOURS", 4).to_i.clamp(1, 24)
  PROFILE_PREPARATION_RETRY_MAX_ATTEMPTS = ENV.fetch("STORY_COMMENT_PROFILE_PREPARATION_RETRY_MAX_ATTEMPTS", 3).to_i.clamp(1, 10)

  retry_on Net::OpenTimeout, Net::ReadTimeout, wait: :polynomially_longer, attempts: 3
  retry_on Errno::ECONNREFUSED, Errno::ECONNRESET, wait: :polynomially_longer, attempts: 3

  def perform(instagram_profile_event_id:, provider: "local", model: nil, requested_by: "system")
    requested_provider = provider.to_s
    provider = "local"
    event = InstagramProfileEvent.find(instagram_profile_event_id)
    return unless event.story_archive_item?
    account = event.instagram_profile&.instagram_account
    profile = event.instagram_profile

    if event.has_llm_generated_comment?
      event.update_columns(
        llm_comment_status: "completed",
        llm_comment_last_error: nil,
        updated_at: Time.current
      )

      Ops::StructuredLogger.info(
        event: "llm_comment.already_completed",
        payload: {
          event_id: event.id,
          instagram_profile_id: event.instagram_profile_id,
          requested_provider: requested_provider,
          requested_by: requested_by
        }
      )
      return
    end

    preparation = prepare_profile_context(profile: profile, account: account)
    persist_profile_preparation_snapshot(event: event, preparation: preparation)
    unless ActiveModel::Type::Boolean.new.cast(preparation[:ready_for_comment_generation] || preparation["ready_for_comment_generation"])
      reason_code = preparation[:reason_code].to_s.presence || preparation["reason_code"].to_s.presence || "profile_comment_preparation_not_ready"
      reason_text = preparation[:reason].to_s.presence || preparation["reason"].to_s.presence || "Profile context is not ready for grounded comment generation."
      raise InstagramProfileEvent::LocalStoryIntelligenceUnavailableError.new(
        reason_text,
        reason: reason_code,
        source: "profile_comment_preparation"
      )
    end

    event.mark_llm_comment_running!(job_id: job_id)
    result = event.generate_llm_comment!(provider: provider, model: model)

    Ops::StructuredLogger.info(
      event: "llm_comment.completed",
      payload: {
        event_id: event.id,
        instagram_profile_id: event.instagram_profile_id,
        provider: event.llm_comment_provider,
        requested_provider: requested_provider,
        model: event.llm_comment_model,
        relevance_score: event.llm_comment_relevance_score,
        requested_by: requested_by,
        source: result[:source]
      }
    )
  rescue InstagramProfileEvent::LocalStoryIntelligenceUnavailableError => e
    event&.mark_llm_comment_skipped!(message: e.message, reason: e.reason, source: e.source)
    retry_result = schedule_profile_preparation_retry_if_needed(
      event: event,
      reason_code: e.reason,
      requested_provider: requested_provider,
      model: model,
      requested_by: requested_by
    )
    event&.queue_llm_comment_generation!(job_id: retry_result[:job_id]) if retry_result[:queued]

    Ops::StructuredLogger.warn(
      event: "llm_comment.skipped_no_context",
      payload: {
        event_id: event&.id,
        instagram_profile_id: event&.instagram_profile_id,
        provider: provider,
        requested_provider: requested_provider,
        model: model,
        requested_by: requested_by,
        reason: e.reason,
        source: e.source,
        error_message: e.message,
        retry_queued: ActiveModel::Type::Boolean.new.cast(retry_result[:queued]),
        retry_reason: retry_result[:reason].to_s.presence,
        retry_job_id: retry_result[:job_id].to_s.presence,
        retry_next_run_at: retry_result[:next_run_at].to_s.presence
      }
    )
  rescue StandardError => e
    event&.mark_llm_comment_failed!(error: e)

    Ops::StructuredLogger.error(
      event: "llm_comment.failed",
      payload: {
        event_id: event&.id,
        instagram_profile_id: event&.instagram_profile_id,
        provider: provider,
        requested_provider: requested_provider,
        model: model,
        requested_by: requested_by,
        error_class: e.class.name,
        error_message: e.message
      }
    )

    raise
  end

  private

  def prepare_profile_context(profile:, account:)
    return { ready_for_comment_generation: false, reason_code: "profile_missing", reason: "Profile missing for event." } unless profile && account

    Ai::ProfileCommentPreparationService.new(account: account, profile: profile).prepare!
  rescue StandardError => e
    {
      ready_for_comment_generation: false,
      reason_code: "profile_preparation_error",
      reason: e.message.to_s,
      error_class: e.class.name
    }
  end

  def persist_profile_preparation_snapshot(event:, preparation:)
    return unless event
    return unless preparation.is_a?(Hash)

    existing = event.llm_comment_metadata.is_a?(Hash) ? event.llm_comment_metadata.deep_dup : {}
    existing["profile_comment_preparation"] = preparation
    event.update_columns(llm_comment_metadata: existing, updated_at: Time.current)
  rescue StandardError
    nil
  end

  def schedule_profile_preparation_retry_if_needed(event:, reason_code:, requested_provider:, model:, requested_by:)
    return { queued: false, reason: "event_missing" } unless event
    return { queued: false, reason: "reason_not_retryable" } unless PROFILE_PREPARATION_RETRY_REASON_CODES.include?(reason_code.to_s)

    metadata = event.llm_comment_metadata.is_a?(Hash) ? event.llm_comment_metadata.deep_dup : {}
    retry_state = metadata["profile_preparation_retry"].is_a?(Hash) ? metadata["profile_preparation_retry"].deep_dup : {}
    attempts = retry_state["attempts"].to_i
    return { queued: false, reason: "retry_attempts_exhausted" } if attempts >= PROFILE_PREPARATION_RETRY_MAX_ATTEMPTS

    next_run_at = parse_time(retry_state["next_run_at"])
    if next_run_at.present? && next_run_at > Time.current
      return { queued: false, reason: "retry_already_scheduled", next_run_at: next_run_at.iso8601 }
    end

    run_at = Time.current + PROFILE_PREPARATION_RETRY_WAIT_HOURS.hours
    job = self.class.set(wait_until: run_at).perform_later(
      instagram_profile_event_id: event.id,
      provider: requested_provider,
      model: model,
      requested_by: "profile_preparation_retry:#{requested_by}"
    )

    retry_state["attempts"] = attempts + 1
    retry_state["last_reason_code"] = reason_code.to_s
    retry_state["last_skipped_at"] = Time.current.iso8601(3)
    retry_state["last_enqueued_at"] = Time.current.iso8601(3)
    retry_state["next_run_at"] = run_at.iso8601(3)
    retry_state["job_id"] = job.job_id
    retry_state["source"] = self.class.name
    metadata["profile_preparation_retry"] = retry_state
    event.update_columns(llm_comment_metadata: metadata, updated_at: Time.current)

    {
      queued: true,
      reason: "profile_analysis_incomplete_retry_queued",
      job_id: job.job_id,
      next_run_at: run_at.iso8601(3)
    }
  rescue StandardError => e
    {
      queued: false,
      reason: "retry_enqueue_failed",
      error_class: e.class.name,
      error_message: e.message.to_s
    }
  end

  def parse_time(value)
    return nil if value.to_s.blank?

    Time.zone.parse(value.to_s)
  rescue StandardError
    nil
  end
end
