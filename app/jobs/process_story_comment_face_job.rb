# frozen_string_literal: true

class ProcessStoryCommentFaceJob < StoryCommentPipelineJob
  queue_as Ops::AiServiceQueueRegistry.queue_symbol_for(:face_analysis)

  def perform(instagram_profile_event_id:, pipeline_run_id:, provider: "local", model: nil, requested_by: "system")
    context = load_story_pipeline_context!(
      instagram_profile_event_id: instagram_profile_event_id,
      pipeline_run_id: pipeline_run_id
    )
    return unless context

    event = context[:event]
    pipeline_state = context[:pipeline_state]
    step = "face_recognition"

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
      message: "Face detection started.",
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

    face_count = payload[:face_count].to_i
    people = Array(payload[:people]).select { |row| row.is_a?(Hash) }.first(12)

    pipeline_state.mark_step_completed!(
      run_id: pipeline_run_id,
      step: step,
      status: "succeeded",
      result: {
        face_count: face_count,
        people_count: people.length,
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
      message: face_count.positive? ? "Face detection completed." : "Face detection completed with no faces.",
      details: {
        pipeline_run_id: pipeline_run_id,
        face_count: face_count,
        people_count: people.length
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
        face_count: face_count,
        people_count: people.length
      }.merge(timing).compact
    )
  rescue StandardError => e
    if context
      context[:pipeline_state].mark_step_completed!(
        run_id: pipeline_run_id,
        step: "face_recognition",
        status: "failed",
        error: truncated_error(e),
        result: {
          reason: "face_stage_failed"
        }
      )
      timing = step_timing_metrics(
        pipeline_state: context[:pipeline_state],
        run_id: pipeline_run_id,
        step: "face_recognition"
      )
      report_stage!(
        event: context[:event],
        stage: "face_recognition",
        state: "failed",
        progress: step_progress("face_recognition", :failed),
        message: "Face detection failed.",
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
        step: "face_recognition",
        active_job_id: job_id,
        queue_name: queue_name,
        error_class: e.class.name,
        error_message: e.message.to_s.byteslice(0, 260)
      }.merge(
        context ? step_timing_metrics(
          pipeline_state: context[:pipeline_state],
          run_id: pipeline_run_id,
          step: "face_recognition"
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
