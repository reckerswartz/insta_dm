require "timeout"

class ProcessPostVisualAnalysisJob < PostAnalysisStepJob
  queue_as Ops::AiServiceQueueRegistry.queue_symbol_for(:visual_analysis)

  MAX_VISUAL_ATTEMPTS = ENV.fetch("AI_VISUAL_MAX_ATTEMPTS", 6).to_i.clamp(1, 20)
  MAX_DEFER_ATTEMPTS = ENV.fetch("AI_VISUAL_MAX_DEFER_ATTEMPTS", 4).to_i.clamp(1, 12)

  retry_on Net::OpenTimeout, Net::ReadTimeout, wait: :polynomially_longer, attempts: 3
  retry_on Errno::ECONNRESET, Errno::ECONNREFUSED, wait: :polynomially_longer, attempts: 3
  retry_on Timeout::Error, wait: :polynomially_longer, attempts: 2

  private

  def step_key
    "visual"
  end

  def resource_task_name
    "visual"
  end

  def audit_service_name
    Ai::Runner.name
  end

  def max_defer_attempts
    MAX_DEFER_ATTEMPTS
  end

  def timeout_seconds
    visual_timeout_seconds
  end

  def step_failure_reason
    "visual_analysis_failed"
  end

  def preflight!(context:, pipeline_run_id:, options: {})
    return true unless visual_attempts_exhausted?(pipeline_state: context[:pipeline_state], pipeline_run_id: pipeline_run_id)

    context[:pipeline_state].mark_step_completed!(
      run_id: pipeline_run_id,
      step: step_key,
      status: "failed",
      error: "visual_attempts_exhausted",
      result: {
        reason: "visual_attempts_exhausted",
        max_attempts: MAX_VISUAL_ATTEMPTS
      }
    )

    Ops::StructuredLogger.warn(
      event: "ai.visual_analysis.exhausted",
      payload: {
        active_job_id: job_id,
        instagram_account_id: context[:account].id,
        instagram_profile_id: context[:profile].id,
        instagram_profile_post_id: context[:post].id,
        pipeline_run_id: pipeline_run_id,
        max_attempts: MAX_VISUAL_ATTEMPTS
      }
    )
    false
  end

  def perform_step!(context:, pipeline_run_id:, options: {})
    account = context[:account]
    profile = context[:profile]
    post = context[:post]
    started_monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC) rescue nil

    builder = Ai::PostAnalysisContextBuilder.new(profile: profile, post: post)
    payload = builder.payload
    media = builder.media_payload
    fingerprint = builder.media_fingerprint(media: media)
    media_summary = media_context(media: media)

    if media_summary[:media_type] == "none"
      Ops::StructuredLogger.warn(
        event: "ai.visual_analysis.media_skipped",
        payload: {
          active_job_id: job_id,
          instagram_account_id: account.id,
          instagram_profile_id: profile.id,
          instagram_profile_post_id: post.id,
          pipeline_run_id: pipeline_run_id,
          reason: media_summary[:reason],
          media_content_type: media_summary[:media_content_type]
        }
      )
    end

    run = Ai::Runner.new(account: account).analyze!(
      purpose: "post",
      analyzable: post,
      payload: payload,
      media: media,
      media_fingerprint: fingerprint,
      provider_options: {
        visual_only: true,
        include_faces: false,
        include_ocr: false,
        include_comment_generation: false
      }
    )

    duration_ms =
      if started_monotonic
        ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_monotonic) * 1000).round
      end

    post.update!(
      ai_provider: run[:provider].key,
      ai_model: run.dig(:result, :model),
      analysis: run.dig(:result, :analysis),
      ai_status: "running"
    )

    {
      provider: run[:provider].key,
      model: run.dig(:result, :model),
      ai_analysis_id: run[:record]&.id,
      cache_hit: ActiveModel::Type::Boolean.new.cast(run[:cached]),
      media_type: media_summary[:media_type],
      media_content_type: media_summary[:media_content_type],
      media_source: media_summary[:media_source],
      media_byte_size: media_summary[:media_byte_size],
      duration_ms: duration_ms
    }
  end

  def step_completion_result(raw_result:, context:, options: {})
    raw_result
  end

  def retryable_step_error?(error)
    retryable_visual_error?(error)
  end

  def visual_attempts_exhausted?(pipeline_state:, pipeline_run_id:)
    attempts = pipeline_state.step_state(run_id: pipeline_run_id, step: "visual").to_h["attempts"].to_i
    attempts >= MAX_VISUAL_ATTEMPTS
  end

  def retryable_visual_error?(error)
    return true if error.is_a?(Timeout::Error)
    return true if error.is_a?(Net::OpenTimeout) || error.is_a?(Net::ReadTimeout)
    return true if error.is_a?(Errno::ECONNRESET) || error.is_a?(Errno::ECONNREFUSED)

    false
  end

  def media_context(media:)
    payload = media.is_a?(Hash) ? media : {}
    bytes = payload[:bytes]
    byte_size = bytes.respond_to?(:bytesize) ? bytes.bytesize : nil

    {
      media_type: payload[:type].to_s.presence || "none",
      media_content_type: payload[:content_type].to_s.presence,
      media_source: payload[:source].to_s.presence,
      media_byte_size: byte_size,
      reason: payload[:reason].to_s.presence
    }
  end

  def visual_timeout_seconds
    ENV.fetch("AI_VISUAL_TIMEOUT_SECONDS", 210).to_i.clamp(30, 600)
  end
end
