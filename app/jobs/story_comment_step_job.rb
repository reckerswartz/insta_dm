# frozen_string_literal: true

class StoryCommentStepJob < StoryCommentPipelineJob
  def perform(instagram_profile_event_id:, pipeline_run_id:, provider: "local", model: nil, requested_by: "system")
    context = load_story_pipeline_context!(
      instagram_profile_event_id: instagram_profile_event_id,
      pipeline_run_id: pipeline_run_id
    )
    return unless context

    event = context[:event]
    pipeline_state = context[:pipeline_state]

    if pipeline_state.pipeline_terminal?(run_id: pipeline_run_id)
      return unless allows_terminal_pipeline_processing?(context: context)
    end
    return if pipeline_state.step_terminal?(run_id: pipeline_run_id, step: step_key)

    pipeline_state.mark_step_running!(
      run_id: pipeline_run_id,
      step: step_key,
      queue_name: queue_name,
      active_job_id: job_id
    )
    report_stage!(
      event: event,
      stage: step_key,
      state: "running",
      progress: step_progress(step_key, :running),
      message: running_message,
      details: {
        pipeline_run_id: pipeline_run_id,
        active_job_id: job_id
      }
    )

    payload = fetch_step_payload(
      event: event,
      pipeline_state: pipeline_state,
      pipeline_run_id: pipeline_run_id
    )
    summary = extract_summary(payload: payload, event: event, context: context)

    pipeline_state.mark_step_completed!(
      run_id: pipeline_run_id,
      step: step_key,
      status: "succeeded",
      result: summary
    )
    timing = step_timing_metrics(
      pipeline_state: pipeline_state,
      run_id: pipeline_run_id,
      step: step_key
    )

    report_stage!(
      event: event,
      stage: step_key,
      state: "completed",
      progress: step_progress(step_key, :completed),
      message: completed_message(summary: summary),
      details: { pipeline_run_id: pipeline_run_id }.merge(completion_details(summary: summary)).merge(timing).compact
    )

    Ops::StructuredLogger.info(
      event: "llm_comment.pipeline.step_completed",
      payload: {
        event_id: event.id,
        instagram_profile_id: event.instagram_profile_id,
        pipeline_run_id: pipeline_run_id,
        step: step_key,
        active_job_id: job_id,
        queue_name: queue_name,
        status: "succeeded"
      }.merge(completion_log_payload(summary: summary)).merge(timing).compact
    )
  rescue StandardError => e
    if context
      context[:pipeline_state].mark_step_completed!(
        run_id: pipeline_run_id,
        step: step_key,
        status: "failed",
        error: truncated_error(e),
        result: {
          reason: failure_reason
        }
      )
      timing = step_timing_metrics(
        pipeline_state: context[:pipeline_state],
        run_id: pipeline_run_id,
        step: step_key
      )
      report_stage!(
        event: context[:event],
        stage: step_key,
        state: "failed",
        progress: step_progress(step_key, :failed),
        message: failed_message,
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
        step: step_key,
        active_job_id: job_id,
        queue_name: queue_name,
        error_class: e.class.name,
        error_message: e.message.to_s.byteslice(0, 260)
      }.merge(
        context ? step_timing_metrics(
          pipeline_state: context[:pipeline_state],
          run_id: pipeline_run_id,
          step: step_key
        ) : {}
      ).compact
    )
    raise
  ensure
    if context && enqueue_finalizer_after_step?
      enqueue_pipeline_finalizer_if_ready(
        context: context,
        pipeline_run_id: pipeline_run_id,
        provider: provider,
        model: model,
        requested_by: requested_by
      )
    end
  end

  private

  def step_key
    raise NotImplementedError
  end

  def running_message
    "Step started."
  end

  def failed_message
    "Step failed."
  end

  def failure_reason
    "#{step_key}_stage_failed"
  end

  def fetch_step_payload(event:, pipeline_state:, pipeline_run_id:)
    LlmComment::StoryIntelligencePayloadResolver.new(
      event: event,
      pipeline_state: pipeline_state,
      pipeline_run_id: pipeline_run_id,
      active_job_id: job_id
    ).fetch!
  end

  def extract_summary(payload:, event:, context:)
    payload.is_a?(Hash) ? payload : {}
  end

  def completion_details(summary:)
    {}
  end

  def completion_log_payload(summary:)
    summary.is_a?(Hash) ? summary.except(:source) : {}
  end

  def completed_message(summary:)
    summary.present? ? "Step completed." : "Step completed."
  end

  def allows_terminal_pipeline_processing?(context:)
    false
  end

  def enqueue_finalizer_after_step?
    true
  end
end
