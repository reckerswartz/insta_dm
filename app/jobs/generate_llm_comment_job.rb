require "timeout"

class GenerateLlmCommentJob < ApplicationJob
  queue_as Ops::AiServiceQueueRegistry.queue_symbol_for(:llm_comment_generation)
  MAX_RESOURCE_DEFER_ATTEMPTS = ENV.fetch("LLM_COMMENT_MAX_RESOURCE_DEFER_ATTEMPTS", "8").to_i.clamp(1, 24)

  retry_on Net::OpenTimeout, Net::ReadTimeout, wait: :polynomially_longer, attempts: 3
  retry_on Errno::ECONNREFUSED, Errno::ECONNRESET, wait: :polynomially_longer, attempts: 3
  retry_on ActiveRecord::Deadlocked, ActiveRecord::LockWaitTimeout, wait: 2.seconds, attempts: 5
  discard_on ActiveRecord::RecordNotFound

  def perform(instagram_profile_event_id:, provider: "local", model: nil, requested_by: "system", defer_attempt: 0, regenerate_all: false)
    guard = Ops::ResourceGuard.allow_ai_task?(task: "llm_comment_generation", queue_name: queue_name)
    unless ActiveModel::Type::Boolean.new.cast(guard[:allow])
      if defer_attempt.to_i >= MAX_RESOURCE_DEFER_ATTEMPTS
        mark_resource_guard_exhausted_failure!(
          instagram_profile_event_id: instagram_profile_event_id,
          reason: guard[:reason].to_s
        )
        return
      end

      retry_seconds = guard[:retry_in_seconds].to_i.clamp(5, 180)
      Ops::StructuredLogger.warn(
        event: "llm_comment.deferred_resource_guard",
        payload: {
          active_job_id: job_id,
          instagram_profile_event_id: instagram_profile_event_id,
          regenerate_all: ActiveModel::Type::Boolean.new.cast(regenerate_all),
          defer_attempt: defer_attempt.to_i,
          reason: guard[:reason].to_s,
          retry_in_seconds: retry_seconds,
          snapshot: guard[:snapshot]
        }
      )

      deferred_job = self.class.set(wait: retry_seconds.seconds).perform_later(
        instagram_profile_event_id: instagram_profile_event_id,
        provider: provider,
        model: model,
        requested_by: requested_by,
        defer_attempt: defer_attempt.to_i + 1,
        regenerate_all: regenerate_all
      )
      refresh_queued_job_reference!(
        instagram_profile_event_id: instagram_profile_event_id,
        deferred_job_id: deferred_job&.job_id.to_s,
        defer_attempt: defer_attempt.to_i + 1,
        reason: guard[:reason].to_s
      )
      return
    end

    timeout_seconds = llm_comment_timeout_seconds

    Timeout.timeout(timeout_seconds) do
      LlmComment::GenerationService.new(
        instagram_profile_event_id: instagram_profile_event_id,
        provider: provider,
        model: model,
        requested_by: requested_by,
        regenerate_all: regenerate_all
      ).call
    end
  rescue Timeout::Error
    mark_timeout_failure!(
      instagram_profile_event_id: instagram_profile_event_id,
      timeout_seconds: timeout_seconds
    )
    Ops::StructuredLogger.error(
      event: "llm_comment.timeout",
      payload: {
        active_job_id: job_id,
        instagram_profile_event_id: instagram_profile_event_id,
        timeout_seconds: timeout_seconds
      }
    )
    nil
  end

  private

  def llm_comment_timeout_seconds
    ENV.fetch("LLM_COMMENT_JOB_TIMEOUT_SECONDS", "300").to_i.clamp(60, 900)
  end

  def refresh_queued_job_reference!(instagram_profile_event_id:, deferred_job_id:, defer_attempt:, reason:)
    return if deferred_job_id.to_s.blank?

    event = InstagramProfileEvent.find_by(id: instagram_profile_event_id)
    return unless event

    event.with_lock do
      event.reload
      return unless event.llm_comment_status.to_s.in?(%w[queued running])

      metadata = event.llm_comment_metadata.is_a?(Hash) ? event.llm_comment_metadata.deep_dup : {}
      metadata["resource_guard_defer"] = {
        "attempt" => defer_attempt.to_i,
        "reason" => reason.to_s,
        "updated_at" => Time.current.iso8601(3)
      }

      event.update_columns(
        llm_comment_status: "queued",
        llm_comment_job_id: deferred_job_id.to_s,
        llm_comment_last_error: nil,
        llm_comment_metadata: metadata,
        updated_at: Time.current
      )
    end
  rescue StandardError
    nil
  end

  def mark_timeout_failure!(instagram_profile_event_id:, timeout_seconds:)
    event = InstagramProfileEvent.find_by(id: instagram_profile_event_id)
    return unless event

    error = Timeout::Error.new("Comment generation timed out after #{timeout_seconds}s")
    event.mark_llm_comment_failed!(error: error)
    event.record_llm_processing_stage!(
      stage: "llm_generation",
      state: "failed",
      progress: 68,
      message: error.message
    )
  rescue StandardError
    nil
  end

  def mark_resource_guard_exhausted_failure!(instagram_profile_event_id:, reason:)
    event = InstagramProfileEvent.find_by(id: instagram_profile_event_id)
    return unless event

    message = "Comment generation deferred too many times due to resource constraints (#{reason.presence || 'unknown'})."
    error = StandardError.new(message)
    event.mark_llm_comment_failed!(error: error)
    event.record_llm_processing_stage!(
      stage: "llm_generation",
      state: "failed",
      progress: 10,
      message: message
    )
  rescue StandardError
    nil
  end
end
