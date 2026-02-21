require "timeout"

class ProcessPostVideoAnalysisJob < PostAnalysisPipelineJob
  queue_as Ops::AiServiceQueueRegistry.queue_symbol_for(:video_analysis)

  MAX_DEFER_ATTEMPTS = ENV.fetch("AI_VIDEO_MAX_DEFER_ATTEMPTS", 4).to_i.clamp(1, 12)

  retry_on Timeout::Error, wait: :polynomially_longer, attempts: 2

  def perform(instagram_account_id:, instagram_profile_id:, instagram_profile_post_id:, pipeline_run_id:, defer_attempt: 0)
    enqueue_finalizer = true
    context = load_pipeline_context!(
      instagram_account_id: instagram_account_id,
      instagram_profile_id: instagram_profile_id,
      instagram_profile_post_id: instagram_profile_post_id,
      pipeline_run_id: pipeline_run_id
    )
    return unless context

    pipeline_state = context[:pipeline_state]
    if pipeline_state.pipeline_terminal?(run_id: pipeline_run_id) || pipeline_state.step_terminal?(run_id: pipeline_run_id, step: "video")
      enqueue_finalizer = false
      Ops::StructuredLogger.info(
        event: "ai.video_analysis.skipped_terminal",
        payload: {
          active_job_id: job_id,
          instagram_account_id: context[:account].id,
          instagram_profile_id: context[:profile].id,
          instagram_profile_post_id: context[:post].id,
          pipeline_run_id: pipeline_run_id
        }
      )
      return
    end

    unless resource_available?(defer_attempt: defer_attempt, context: context, pipeline_run_id: pipeline_run_id)
      return
    end

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
      PostVideoContextExtractionService.new.extract(
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
        skipped: ActiveModel::Type::Boolean.new.cast(result[:skipped]),
        processing_mode: result[:processing_mode].to_s,
        static: ActiveModel::Type::Boolean.new.cast(result[:static]),
        semantic_route: result[:semantic_route].to_s.presence,
        duration_seconds: result[:duration_seconds],
        has_audio: ActiveModel::Type::Boolean.new.cast(result[:has_audio]),
        transcript_present: result[:transcript].to_s.present?,
        topics_count: Array(result[:topics]).length
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
    if context && enqueue_finalizer
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
    post.with_lock do
      post.reload
      analysis = post.analysis.is_a?(Hash) ? post.analysis.deep_dup : {}
      metadata = post.metadata.is_a?(Hash) ? post.metadata.deep_dup : {}

      analysis["video_processing_mode"] = normalized[:processing_mode].to_s if normalized.key?(:processing_mode)
      analysis["video_static_detected"] = ActiveModel::Type::Boolean.new.cast(normalized[:static]) if normalized.key?(:static)
      analysis["video_semantic_route"] = normalized[:semantic_route].to_s if normalized[:semantic_route].to_s.present?
      analysis["video_duration_seconds"] = normalized[:duration_seconds] if normalized.key?(:duration_seconds)
      analysis["video_context_summary"] = normalized[:context_summary].to_s if normalized[:context_summary].to_s.present?
      analysis["transcript"] = normalized[:transcript].to_s if normalized[:transcript].to_s.present?
      analysis["video_topics"] = normalized[:topics] if normalized[:topics].is_a?(Array)
      analysis["video_objects"] = normalized[:objects] if normalized[:objects].is_a?(Array)
      analysis["video_scenes"] = normalized[:scenes] if normalized[:scenes].is_a?(Array)
      analysis["video_hashtags"] = normalized[:hashtags] if normalized[:hashtags].is_a?(Array)
      analysis["video_mentions"] = normalized[:mentions] if normalized[:mentions].is_a?(Array)
      analysis["video_profile_handles"] = normalized[:profile_handles] if normalized[:profile_handles].is_a?(Array)
      analysis["video_ocr_text"] = normalized[:ocr_text].to_s if normalized[:ocr_text].to_s.present?
      analysis["video_ocr_blocks"] = normalized[:ocr_blocks] if normalized[:ocr_blocks].is_a?(Array)

      analysis["topics"] = merge_strings(analysis["topics"], normalized[:topics], limit: 40)
      analysis["objects"] = merge_strings(analysis["objects"], normalized[:objects], limit: 50)
      analysis["hashtags"] = merge_strings(analysis["hashtags"], normalized[:hashtags], limit: 50)
      analysis["mentions"] = merge_strings(analysis["mentions"], normalized[:mentions], limit: 50)

      if analysis["ocr_text"].to_s.blank? && normalized[:ocr_text].to_s.present?
        analysis["ocr_text"] = normalized[:ocr_text].to_s
      end
      if Array(analysis["ocr_blocks"]).empty? && normalized[:ocr_blocks].is_a?(Array)
        analysis["ocr_blocks"] = normalized[:ocr_blocks].first(40)
      end

      metadata["video_processing"] = {
        "skipped" => ActiveModel::Type::Boolean.new.cast(normalized[:skipped]),
        "processing_mode" => normalized[:processing_mode].to_s,
        "static" => ActiveModel::Type::Boolean.new.cast(normalized[:static]),
        "semantic_route" => normalized[:semantic_route].to_s.presence,
        "duration_seconds" => normalized[:duration_seconds],
        "has_audio" => ActiveModel::Type::Boolean.new.cast(normalized[:has_audio]),
        "transcript" => normalized[:transcript].to_s.presence,
        "topics" => normalized[:topics],
        "objects" => normalized[:objects],
        "scenes" => normalized[:scenes],
        "hashtags" => normalized[:hashtags],
        "mentions" => normalized[:mentions],
        "profile_handles" => normalized[:profile_handles],
        "ocr_text" => normalized[:ocr_text].to_s.presence,
        "ocr_blocks" => normalized[:ocr_blocks],
        "context_summary" => normalized[:context_summary].to_s.presence,
        "metadata" => normalized[:metadata],
        "updated_at" => Time.current.iso8601(3)
      }.compact

      post.update!(analysis: analysis, metadata: metadata)
    end
  end

  def normalize_video_result(result)
    row = result.is_a?(Hash) ? result : {}
    {
      skipped: value_for(row, :skipped),
      processing_mode: value_for(row, :processing_mode).to_s.presence || "dynamic_video",
      static: value_for(row, :static),
      semantic_route: value_for(row, :semantic_route),
      duration_seconds: value_for(row, :duration_seconds),
      has_audio: value_for(row, :has_audio),
      transcript: value_for(row, :transcript),
      topics: normalized_strings(value_for(row, :topics), limit: 40),
      objects: normalized_strings(value_for(row, :objects), limit: 50),
      scenes: Array(value_for(row, :scenes)).select { |value| value.is_a?(Hash) }.first(50),
      hashtags: normalized_strings(value_for(row, :hashtags), limit: 50),
      mentions: normalized_strings(value_for(row, :mentions), limit: 50),
      profile_handles: normalized_strings(value_for(row, :profile_handles), limit: 50),
      ocr_text: value_for(row, :ocr_text),
      ocr_blocks: Array(value_for(row, :ocr_blocks)).select { |value| value.is_a?(Hash) }.first(80),
      context_summary: value_for(row, :context_summary),
      metadata: row[:metadata] || row["metadata"] || { reason: row[:reason] || row["reason"] }
    }
  end

  def normalized_strings(values, limit:)
    Array(values).map(&:to_s).map(&:strip).reject(&:blank?).uniq.first(limit)
  end

  def merge_strings(existing, incoming, limit:)
    normalized_strings(Array(existing) + Array(incoming), limit: limit)
  end

  def value_for(row, key)
    return row[key] if row.key?(key)
    return row[key.to_s] if row.key?(key.to_s)

    nil
  end

  def video_timeout_seconds
    ENV.fetch("AI_VIDEO_TIMEOUT_SECONDS", 180).to_i.clamp(20, 420)
  end
end
