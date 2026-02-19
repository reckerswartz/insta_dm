require "timeout"

class ProcessPostVideoAnalysisJob < PostAnalysisPipelineJob
  queue_as :video_processing_queue

  MAX_DEFER_ATTEMPTS = ENV.fetch("AI_VIDEO_MAX_DEFER_ATTEMPTS", 4).to_i.clamp(1, 12)

  retry_on Timeout::Error, wait: :polynomially_longer, attempts: 2

  def perform(instagram_account_id:, instagram_profile_id:, instagram_profile_post_id:, pipeline_run_id:, defer_attempt: 0)
    context = load_pipeline_context!(
      instagram_account_id: instagram_account_id,
      instagram_profile_id: instagram_profile_id,
      instagram_profile_post_id: instagram_profile_post_id,
      pipeline_run_id: pipeline_run_id
    )
    return unless context

    unless resource_available?(defer_attempt: defer_attempt, context: context, pipeline_run_id: pipeline_run_id)
      return
    end

    pipeline_state = context[:pipeline_state]
    profile = context[:profile]
    post = context[:post]

    pipeline_state.mark_step_running!(
      run_id: pipeline_run_id,
      step: "video",
      queue_name: queue_name,
      active_job_id: job_id
    )

    builder = Ai::PostAnalysisContextBuilder.new(profile: profile, post: post)
    payload = builder.video_payload

    if ActiveModel::Type::Boolean.new.cast(payload[:skipped])
      persist_video_analysis!(post: post, result: payload)
      pipeline_state.mark_step_completed!(
        run_id: pipeline_run_id,
        step: "video",
        status: "succeeded",
        result: {
          skipped: true,
          reason: payload[:reason].to_s
        }
      )
      return
    end

    result = Timeout.timeout(video_timeout_seconds) do
      VideoFrameChangeDetectorService.new.classify(
        video_bytes: payload[:video_bytes],
        reference_id: payload[:reference_id].to_s.presence || "post_media_#{post.id}",
        content_type: payload[:content_type]
      )
    end

    persist_video_analysis!(post: post, result: result)

    pipeline_state.mark_step_completed!(
      run_id: pipeline_run_id,
      step: "video",
      status: "succeeded",
      result: {
        skipped: false,
        processing_mode: result[:processing_mode].to_s,
        static: ActiveModel::Type::Boolean.new.cast(result[:static]),
        duration_seconds: result[:duration_seconds]
      }
    )
  rescue StandardError => e
    context&.dig(:pipeline_state)&.mark_step_completed!(
      run_id: pipeline_run_id,
      step: "video",
      status: "failed",
      error: format_error(e),
      result: {
        reason: "video_analysis_failed"
      }
    )
    raise
  ensure
    if context
      enqueue_pipeline_finalizer(
        account: context[:account],
        profile: context[:profile],
        post: context[:post],
        pipeline_run_id: pipeline_run_id
      )
    end
  end

  private

  def resource_available?(defer_attempt:, context:, pipeline_run_id:)
    guard = Ops::ResourceGuard.allow_ai_task?(task: "video", queue_name: queue_name, critical: false)
    return true if ActiveModel::Type::Boolean.new.cast(guard[:allow])

    if defer_attempt.to_i >= MAX_DEFER_ATTEMPTS
      context[:pipeline_state].mark_step_completed!(
        run_id: pipeline_run_id,
        step: "video",
        status: "failed",
        error: "resource_guard_exhausted: #{guard[:reason]}",
        result: {
          reason: "resource_constraints",
          snapshot: guard[:snapshot]
        }
      )
      return false
    end

    retry_seconds = guard[:retry_in_seconds].to_i
    retry_seconds = 20 if retry_seconds <= 0

    context[:pipeline_state].mark_step_queued!(
      run_id: pipeline_run_id,
      step: "video",
      queue_name: queue_name,
      active_job_id: job_id,
      result: {
        reason: "resource_constrained",
        defer_attempt: defer_attempt.to_i,
        retry_in_seconds: retry_seconds,
        snapshot: guard[:snapshot]
      }
    )

    self.class.set(wait: retry_seconds.seconds).perform_later(
      instagram_account_id: context[:account].id,
      instagram_profile_id: context[:profile].id,
      instagram_profile_post_id: context[:post].id,
      pipeline_run_id: pipeline_run_id,
      defer_attempt: defer_attempt.to_i + 1
    )

    false
  end

  def persist_video_analysis!(post:, result:)
    normalized = normalize_video_result(result)
    analysis = post.analysis.is_a?(Hash) ? post.analysis.deep_dup : {}
    metadata = post.metadata.is_a?(Hash) ? post.metadata.deep_dup : {}

    analysis["video_processing_mode"] = normalized[:processing_mode].to_s if normalized.key?(:processing_mode)
    analysis["video_static_detected"] = ActiveModel::Type::Boolean.new.cast(normalized[:static]) if normalized.key?(:static)
    analysis["video_duration_seconds"] = normalized[:duration_seconds] if normalized.key?(:duration_seconds)

    metadata["video_processing"] = {
      "processing_mode" => normalized[:processing_mode].to_s,
      "static" => ActiveModel::Type::Boolean.new.cast(normalized[:static]),
      "duration_seconds" => normalized[:duration_seconds],
      "metadata" => normalized[:metadata],
      "updated_at" => Time.current.iso8601(3)
    }.compact

    post.update!(analysis: analysis, metadata: metadata)
  end

  def normalize_video_result(result)
    row = result.is_a?(Hash) ? result : {}
    {
      processing_mode: row[:processing_mode] || row["processing_mode"] || "dynamic_video",
      static: row[:static] || row["static"],
      duration_seconds: row[:duration_seconds] || row["duration_seconds"],
      metadata: row[:metadata] || row["metadata"] || { reason: row[:reason] || row["reason"] }
    }
  end

  def video_timeout_seconds
    ENV.fetch("AI_VIDEO_TIMEOUT_SECONDS", 180).to_i.clamp(20, 420)
  end
end
