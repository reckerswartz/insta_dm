require "timeout"

class GenerateLlmCommentJob < ApplicationJob
  queue_as Ops::AiServiceQueueRegistry.queue_symbol_for(:llm_comment_generation)
  MAX_RESOURCE_DEFER_ATTEMPTS = ENV.fetch("LLM_COMMENT_MAX_RESOURCE_DEFER_ATTEMPTS", "8").to_i.clamp(1, 24)
  LONG_RUNNING_TIMEOUT_SECONDS = ENV.fetch("LLM_COMMENT_LONG_RUNNING_TIMEOUT_SECONDS", "1800").to_i.clamp(300, 14_400)

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

    # Local LLM inference can legitimately run for several minutes (or longer) on
    # constrained hardware. We keep a long guardrail timeout to prevent true
    # runaway jobs, but avoid failing at the old 5-minute mark.
    timeout_seconds = llm_comment_timeout_seconds(instagram_profile_event_id: instagram_profile_event_id)

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
    requeue_after_timeout!(
      instagram_profile_event_id: instagram_profile_event_id,
      timeout_seconds: timeout_seconds,
      provider: provider,
      model: model,
      requested_by: requested_by,
      defer_attempt: defer_attempt,
      regenerate_all: regenerate_all
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

  def llm_comment_timeout_seconds(instagram_profile_event_id:)
    event = InstagramProfileEvent.find_by(id: instagram_profile_event_id)
    return LONG_RUNNING_TIMEOUT_SECONDS unless event

    media_type = event.metadata.is_a?(Hash) ? event.metadata["media_type"].to_s : ""
    content_type = event.media.attached? ? event.media.blob&.content_type.to_s : ""
    video_heavy = media_type.include?("video") || content_type.start_with?("video/")
    video_heavy ? LONG_RUNNING_TIMEOUT_SECONDS : [LONG_RUNNING_TIMEOUT_SECONDS, 900].max
  rescue StandardError
    LONG_RUNNING_TIMEOUT_SECONDS
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

  def requeue_after_timeout!(instagram_profile_event_id:, timeout_seconds:, provider:, model:, requested_by:, defer_attempt:, regenerate_all:)
    event = InstagramProfileEvent.find_by(id: instagram_profile_event_id)
    return unless event

    event.record_llm_processing_stage!(
      stage: "llm_generation",
      state: "running",
      progress: 68,
      message: "LLM worker exceeded #{timeout_seconds}s and is being resumed from the last completed stage."
    )
    retry_job = self.class.set(wait: 20.seconds).perform_later(
      instagram_profile_event_id: instagram_profile_event_id,
      provider: provider,
      model: model,
      requested_by: "timeout_resume:#{requested_by}",
      defer_attempt: defer_attempt.to_i,
      regenerate_all: regenerate_all
    )

    metadata = event.llm_comment_metadata.is_a?(Hash) ? event.llm_comment_metadata.deep_dup : {}
    timeout_state = metadata["timeout_resume"].is_a?(Hash) ? metadata["timeout_resume"].deep_dup : {}
    timeout_state["last_timeout_at"] = Time.current.iso8601(3)
    timeout_state["timeout_seconds"] = timeout_seconds.to_i
    timeout_state["retry_job_id"] = retry_job&.job_id.to_s.presence
    timeout_state["source_job_id"] = job_id
    timeout_state["note"] = "LLM inference may take significant time on local resources."
    metadata["timeout_resume"] = timeout_state

    event.update_columns(
      llm_comment_status: "queued",
      llm_comment_job_id: retry_job&.job_id.to_s.presence || event.llm_comment_job_id,
      llm_comment_last_error: nil,
      llm_comment_metadata: metadata,
      updated_at: Time.current
    )

    event.record_llm_processing_stage!(
      stage: "queue_wait",
      state: "queued",
      progress: 0,
      message: "Resumed LLM job was queued after timeout guardrail."
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
