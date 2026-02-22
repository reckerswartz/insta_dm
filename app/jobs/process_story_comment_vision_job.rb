# frozen_string_literal: true

class ProcessStoryCommentVisionJob < StoryCommentPipelineJob
  queue_as Ops::AiServiceQueueRegistry.queue_symbol_for(:visual_analysis)

  def perform(instagram_profile_event_id:, pipeline_run_id:, provider: "local", model: nil, requested_by: "system")
    context = load_story_pipeline_context!(
      instagram_profile_event_id: instagram_profile_event_id,
      pipeline_run_id: pipeline_run_id
    )
    return unless context

    event = context[:event]
    pipeline_state = context[:pipeline_state]
    step = "vision_detection"

    return if pipeline_state.pipeline_terminal?(run_id: pipeline_run_id)
    return if pipeline_state.step_terminal?(run_id: pipeline_run_id, step: step)

    pipeline_state.mark_step_running!(
      run_id: pipeline_run_id,
      step: step,
      queue_name: queue_name,
      active_job_id: job_id
    )
    report_stage!(
      event: event,
      stage: step,
      state: "running",
      progress: step_progress(step, :running),
      message: "Region and vision detection started.",
      details: {
        pipeline_run_id: pipeline_run_id,
        active_job_id: job_id
      }
    )

    payload = LlmComment::StoryIntelligencePayloadResolver.new(
      event: event,
      pipeline_state: pipeline_state,
      pipeline_run_id: pipeline_run_id,
      active_job_id: job_id
    ).fetch!

    object_detections = Array(payload[:object_detections]).select { |row| row.is_a?(Hash) }.first(120)
    scenes = Array(payload[:scenes]).select { |row| row.is_a?(Hash) }.first(80)
    objects = Array(payload[:objects]).map(&:to_s).reject(&:blank?).uniq.first(40)
    topics = Array(payload[:topics]).map(&:to_s).reject(&:blank?).uniq.first(40)

    pipeline_state.mark_step_completed!(
      run_id: pipeline_run_id,
      step: step,
      status: "succeeded",
      result: {
        objects_count: objects.length,
        object_detections_count: object_detections.length,
        scenes_count: scenes.length,
        topics_count: topics.length,
        source: payload[:source].to_s.presence
      }
    )
    timing = step_timing_metrics(
      pipeline_state: pipeline_state,
      run_id: pipeline_run_id,
      step: step
    )

    report_stage!(
      event: event,
      stage: step,
      state: "completed",
      progress: step_progress(step, :completed),
      message: "Region and vision detection completed.",
      details: {
        pipeline_run_id: pipeline_run_id,
        objects_count: objects.length,
        object_detections_count: object_detections.length,
        scenes_count: scenes.length
      }.merge(timing).compact
    )

    Ops::StructuredLogger.info(
      event: "llm_comment.pipeline.step_completed",
      payload: {
        event_id: event.id,
        instagram_profile_id: event.instagram_profile_id,
        pipeline_run_id: pipeline_run_id,
        step: step,
        active_job_id: job_id,
        queue_name: queue_name,
        status: "succeeded",
        objects_count: objects.length,
        object_detections_count: object_detections.length,
        scenes_count: scenes.length
      }.merge(timing).compact
    )
  rescue StandardError => e
    if context
      context[:pipeline_state].mark_step_completed!(
        run_id: pipeline_run_id,
        step: "vision_detection",
        status: "failed",
        error: truncated_error(e),
        result: {
          reason: "vision_stage_failed"
        }
      )
      timing = step_timing_metrics(
        pipeline_state: context[:pipeline_state],
        run_id: pipeline_run_id,
        step: "vision_detection"
      )
      report_stage!(
        event: context[:event],
        stage: "vision_detection",
        state: "failed",
        progress: step_progress("vision_detection", :failed),
        message: "Region and vision detection failed.",
        details: {
          pipeline_run_id: pipeline_run_id,
          error_class: e.class.name,
          error_message: e.message.to_s.byteslice(0, 200)
        }.merge(timing).compact
      )
    end

    Ops::StructuredLogger.error(
      event: "llm_comment.pipeline.step_failed",
      payload: {
        event_id: context&.dig(:event)&.id || instagram_profile_event_id,
        pipeline_run_id: pipeline_run_id,
        step: "vision_detection",
        active_job_id: job_id,
        queue_name: queue_name,
        error_class: e.class.name,
        error_message: e.message.to_s.byteslice(0, 260)
      }.merge(
        context ? step_timing_metrics(
          pipeline_state: context[:pipeline_state],
          run_id: pipeline_run_id,
          step: "vision_detection"
        ) : {}
      ).compact
    )
    raise
  ensure
    if context
      enqueue_pipeline_finalizer_if_ready(
        context: context,
        pipeline_run_id: pipeline_run_id,
        provider: provider,
        model: model,
        requested_by: requested_by
      )
    end
  end
end
