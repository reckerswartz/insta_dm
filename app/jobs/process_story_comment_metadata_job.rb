# frozen_string_literal: true

class ProcessStoryCommentMetadataJob < StoryCommentPipelineJob
  queue_as Ops::AiServiceQueueRegistry.queue_symbol_for(:metadata_tagging)

  def perform(instagram_profile_event_id:, pipeline_run_id:, provider: "local", model: nil, requested_by: "system")
    context = load_story_pipeline_context!(
      instagram_profile_event_id: instagram_profile_event_id,
      pipeline_run_id: pipeline_run_id
    )
    return unless context

    event = context[:event]
    pipeline_state = context[:pipeline_state]
    step = "metadata_extraction"

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
      message: "Metadata extraction started.",
      details: {
        pipeline_run_id: pipeline_run_id,
        active_job_id: job_id
      }
    )

    metadata = event.metadata.is_a?(Hash) ? event.metadata : {}
    blob = event.media.attached? ? event.media.blob : nil
    result = {
      story_id: metadata["story_id"].to_s.presence,
      media_type: metadata["media_type"].to_s.presence || blob&.content_type.to_s.presence,
      media_content_type: blob&.content_type.to_s.presence || metadata["media_content_type"].to_s.presence,
      media_bytes: blob&.byte_size || metadata["media_bytes"],
      media_width: metadata["media_width"],
      media_height: metadata["media_height"],
      story_url: metadata["story_url"].to_s.presence || metadata["permalink"].to_s.presence,
      uploaded_at: metadata["upload_time"].to_s.presence || metadata["taken_at"].to_s.presence,
      downloaded_at: metadata["downloaded_at"].to_s.presence || event.occurred_at&.iso8601
    }.compact

    pipeline_state.mark_step_completed!(
      run_id: pipeline_run_id,
      step: step,
      status: "succeeded",
      result: result
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
      message: "Metadata extraction completed.",
      details: {
        pipeline_run_id: pipeline_run_id,
        media_content_type: result[:media_content_type],
        media_bytes: result[:media_bytes]
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
        media_content_type: result[:media_content_type],
        media_bytes: result[:media_bytes]
      }.merge(timing).compact
    )
  rescue StandardError => e
    if context
      context[:pipeline_state].mark_step_completed!(
        run_id: pipeline_run_id,
        step: "metadata_extraction",
        status: "failed",
        error: truncated_error(e),
        result: {
          reason: "metadata_stage_failed"
        }
      )
      timing = step_timing_metrics(
        pipeline_state: context[:pipeline_state],
        run_id: pipeline_run_id,
        step: "metadata_extraction"
      )
      report_stage!(
        event: context[:event],
        stage: "metadata_extraction",
        state: "failed",
        progress: step_progress("metadata_extraction", :failed),
        message: "Metadata extraction failed.",
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
        step: "metadata_extraction",
        active_job_id: job_id,
        queue_name: queue_name,
        error_class: e.class.name,
        error_message: e.message.to_s.byteslice(0, 260)
      }.merge(
        context ? step_timing_metrics(
          pipeline_state: context[:pipeline_state],
          run_id: pipeline_run_id,
          step: "metadata_extraction"
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
