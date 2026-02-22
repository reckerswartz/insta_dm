# frozen_string_literal: true

class GenerateStoryCommentFromPipelineJob < StoryCommentPipelineJob
  queue_as Ops::AiServiceQueueRegistry.queue_symbol_for(:llm_comment_generation)

  def perform(instagram_profile_event_id:, pipeline_run_id:, provider: "local", model: nil, requested_by: "system")
    context = load_story_pipeline_context!(
      instagram_profile_event_id: instagram_profile_event_id,
      pipeline_run_id: pipeline_run_id
    )
    return unless context

    event = context[:event]
    pipeline_state = context[:pipeline_state]
    return if pipeline_state.pipeline_terminal?(run_id: pipeline_run_id)

    generation_status = context.dig(:pipeline, "generation", "status").to_s
    unless generation_status == "running"
      acquired = pipeline_state.mark_generation_started!(
        run_id: pipeline_run_id,
        active_job_id: job_id
      )
      return unless acquired
    end

    failed_steps = pipeline_state.failed_steps(run_id: pipeline_run_id)
    step_rollup = pipeline_step_rollup(pipeline_state: pipeline_state, run_id: pipeline_run_id)
    report_stage!(
      event: event,
      stage: "parallel_services",
      state: failed_steps.empty? ? "completed" : "completed_with_warnings",
      progress: 40,
      message: failed_steps.empty? ? "Parallel analysis jobs completed." : "Parallel analysis jobs completed with warnings.",
      details: {
        pipeline_run_id: pipeline_run_id,
        failed_steps: failed_steps,
        step_rollup: step_rollup
      }
    )
    report_stage!(
      event: event,
      stage: "context_matching",
      state: "running",
      progress: 44,
      message: "Prompt context construction started after parallel jobs completed.",
      details: {
        pipeline_run_id: pipeline_run_id
      }
    )

    generation_result = nil
    with_pipeline_heartbeat(
      event: event,
      pipeline_state: pipeline_state,
      pipeline_run_id: pipeline_run_id,
      step: "llm_generation",
      interval_seconds: 20,
      progress: 68,
      # Local model inference can be slow under CPU/GPU pressure; heartbeats make
      # prolonged processing explicit so operators can distinguish progress vs. failure.
      message: "LLM is still processing on local resources; large-model inference may take several minutes."
    ) do
      payload = LlmComment::StoryIntelligencePayloadResolver.new(
        event: event,
        pipeline_state: pipeline_state,
        pipeline_run_id: pipeline_run_id,
        active_job_id: job_id
      ).fetch!

      event.persist_local_story_intelligence!(payload)
      report_stage!(
        event: event,
        stage: "context_matching",
        state: "completed",
        progress: 46,
        message: "Context matching completed.",
        details: {
          pipeline_run_id: pipeline_run_id,
          source: payload[:source].to_s.presence
        }
      )

      generation_result = LlmComment::EventGenerationPipeline.new(
        event: event,
        provider: provider,
        model: model,
        skip_media_stage_reporting: true
      ).call
    end

    pipeline_state.mark_pipeline_finished!(
      run_id: pipeline_run_id,
      status: "completed",
      details: {
        completed_by: self.class.name,
        active_job_id: job_id,
        completed_at: Time.current.iso8601(3),
        failed_steps: failed_steps,
        step_rollup: step_rollup
      }
    )
    timing_rollup = pipeline_timing_rollup(pipeline_state: pipeline_state, run_id: pipeline_run_id)

    Ops::StructuredLogger.info(
      event: "llm_comment.pipeline.completed",
      payload: {
        event_id: event.id,
        instagram_profile_id: event.instagram_profile_id,
        pipeline_run_id: pipeline_run_id,
        active_job_id: job_id,
        provider: provider,
        model: model,
        requested_by: requested_by,
        failed_steps: failed_steps,
        step_rollup: step_rollup,
        selected_comment: generation_result[:selected_comment].to_s.byteslice(0, 180),
        relevance_score: generation_result[:relevance_score]
      }.merge(timing_rollup)
    )
  rescue StandardError => e
    if context
      fail_pipeline!(
        event: context[:event],
        pipeline_state: context[:pipeline_state],
        pipeline_run_id: pipeline_run_id,
        error: truncated_error(e),
        active_job_id: job_id
      )
    end

    Ops::StructuredLogger.error(
      event: "llm_comment.pipeline.failed",
      payload: {
        event_id: context&.dig(:event)&.id || instagram_profile_event_id,
        pipeline_run_id: pipeline_run_id,
        active_job_id: job_id,
        error_class: e.class.name,
        error_message: e.message.to_s.byteslice(0, 260)
      }.merge(
        context ? { step_rollup: pipeline_step_rollup(pipeline_state: context[:pipeline_state], run_id: pipeline_run_id) } : {}
      ).merge(
        context ? pipeline_timing_rollup(pipeline_state: context[:pipeline_state], run_id: pipeline_run_id) : {}
      )
    )
    raise
  end

  private

  def fail_pipeline!(event:, pipeline_state:, pipeline_run_id:, error:, active_job_id: nil)
    step_rollup = pipeline_step_rollup(pipeline_state: pipeline_state, run_id: pipeline_run_id)
    pipeline_state.mark_generation_failed!(
      run_id: pipeline_run_id,
      active_job_id: active_job_id.to_s.presence || job_id,
      error: error.to_s
    )
    pipeline_state.mark_pipeline_finished!(
      run_id: pipeline_run_id,
      status: "failed",
      details: {
        failed_by: self.class.name,
        active_job_id: active_job_id.to_s.presence || job_id,
        failed_at: Time.current.iso8601(3),
        reason: error.to_s,
        step_rollup: step_rollup
      }
    )
    timing_rollup = pipeline_timing_rollup(pipeline_state: pipeline_state, run_id: pipeline_run_id)

    event.mark_llm_comment_failed!(error: StandardError.new(error.to_s))
    report_stage!(
      event: event,
      stage: "llm_generation",
      state: "failed",
      progress: 68,
      message: "Comment generation pipeline failed.",
      details: {
        pipeline_run_id: pipeline_run_id,
        reason: error.to_s,
        step_rollup: step_rollup
      }.merge(timing_rollup)
    )
  rescue StandardError
    nil
  end
end
