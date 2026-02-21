require "timeout"

class GenerateLlmCommentJob < ApplicationJob
  queue_as :ai

  retry_on Net::OpenTimeout, Net::ReadTimeout, wait: :polynomially_longer, attempts: 3
  retry_on Errno::ECONNREFUSED, Errno::ECONNRESET, wait: :polynomially_longer, attempts: 3
  retry_on ActiveRecord::Deadlocked, ActiveRecord::LockWaitTimeout, wait: 2.seconds, attempts: 5
  retry_on Timeout::Error, wait: :polynomially_longer, attempts: 2
  discard_on ActiveRecord::RecordNotFound

  def perform(instagram_profile_event_id:, provider: "local", model: nil, requested_by: "system")
    guard = Ops::ResourceGuard.allow_ai_task?(task: "llm_comment_generation", queue_name: queue_name)
    unless ActiveModel::Type::Boolean.new.cast(guard[:allow])
      retry_seconds = guard[:retry_in_seconds].to_i.clamp(5, 180)
      Ops::StructuredLogger.warn(
        event: "llm_comment.deferred_resource_guard",
        payload: {
          active_job_id: job_id,
          instagram_profile_event_id: instagram_profile_event_id,
          reason: guard[:reason].to_s,
          retry_in_seconds: retry_seconds,
          snapshot: guard[:snapshot]
        }
      )

      self.class.set(wait: retry_seconds.seconds).perform_later(
        instagram_profile_event_id: instagram_profile_event_id,
        provider: provider,
        model: model,
        requested_by: requested_by
      )
      return
    end

    timeout_seconds = ENV.fetch("LLM_COMMENT_JOB_TIMEOUT_SECONDS", "120").to_i.clamp(30, 600)

    Timeout.timeout(timeout_seconds) do
      LlmComment::GenerationService.new(
        instagram_profile_event_id: instagram_profile_event_id,
        provider: provider,
        model: model,
        requested_by: requested_by
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
    raise
  end

  private

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
end
