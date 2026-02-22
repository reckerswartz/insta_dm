# frozen_string_literal: true

class ProcessStoryCommentOcrJob < StoryCommentPipelineJob
  queue_as Ops::AiServiceQueueRegistry.queue_symbol_for(:ocr_analysis)

  def perform(instagram_profile_event_id:, pipeline_run_id:, provider: "local", model: nil, requested_by: "system")
    context = load_story_pipeline_context!(
      instagram_profile_event_id: instagram_profile_event_id,
      pipeline_run_id: pipeline_run_id
    )
    return unless context

    event = context[:event]
    pipeline_state = context[:pipeline_state]
    step = "ocr_analysis"

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
      message: "OCR processing started.",
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

    ocr_text = payload[:ocr_text].to_s.presence
    ocr_blocks = Array(payload[:ocr_blocks]).select { |row| row.is_a?(Hash) }.first(120)

    pipeline_state.mark_step_completed!(
      run_id: pipeline_run_id,
      step: step,
      status: "succeeded",
      result: {
        text_present: ocr_text.present?,
        ocr_blocks_count: ocr_blocks.length,
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
      message: ocr_text.present? ? "OCR processing completed." : "OCR completed with limited text.",
      details: {
        pipeline_run_id: pipeline_run_id,
        text_present: ocr_text.present?,
        ocr_blocks_count: ocr_blocks.length
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
        text_present: ocr_text.present?,
        ocr_blocks_count: ocr_blocks.length
      }.merge(timing).compact
    )
  rescue StandardError => e
    if context
      context[:pipeline_state].mark_step_completed!(
        run_id: pipeline_run_id,
        step: "ocr_analysis",
        status: "failed",
        error: truncated_error(e),
        result: {
          reason: "ocr_stage_failed"
        }
      )
      timing = step_timing_metrics(
        pipeline_state: context[:pipeline_state],
        run_id: pipeline_run_id,
        step: "ocr_analysis"
      )
      report_stage!(
        event: context[:event],
        stage: "ocr_analysis",
        state: "failed",
        progress: step_progress("ocr_analysis", :failed),
        message: "OCR processing failed.",
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
        step: "ocr_analysis",
        active_job_id: job_id,
        queue_name: queue_name,
        error_class: e.class.name,
        error_message: e.message.to_s.byteslice(0, 260)
      }.merge(
        context ? step_timing_metrics(
          pipeline_state: context[:pipeline_state],
          run_id: pipeline_run_id,
          step: "ocr_analysis"
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
