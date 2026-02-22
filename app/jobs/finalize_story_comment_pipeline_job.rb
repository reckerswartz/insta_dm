# frozen_string_literal: true

class FinalizeStoryCommentPipelineJob < StoryCommentPipelineJob
  queue_as Ops::AiServiceQueueRegistry.queue_symbol_for(:pipeline_orchestration)

  MAX_FINALIZE_ATTEMPTS = ENV.fetch("LLM_COMMENT_PIPELINE_FINALIZE_ATTEMPTS", "120").to_i.clamp(24, 240)

  def perform(instagram_profile_event_id:, pipeline_run_id:, provider: "local", model: nil, requested_by: "system", attempts: 0)
    context = load_story_pipeline_context!(
      instagram_profile_event_id: instagram_profile_event_id,
      pipeline_run_id: pipeline_run_id
    )
    return unless context

    event = context[:event]
    pipeline_state = context[:pipeline_state]

    if pipeline_state.pipeline_terminal?(run_id: pipeline_run_id)
      Ops::StructuredLogger.info(
        event: "llm_comment.pipeline.finalizer_skipped_terminal",
        payload: {
          event_id: event.id,
          instagram_profile_id: event.instagram_profile_id,
          pipeline_run_id: pipeline_run_id,
          active_job_id: job_id
        }
      )
      return
    end

    unless pipeline_state.all_steps_terminal?(run_id: pipeline_run_id)
      if attempts.to_i >= MAX_FINALIZE_ATTEMPTS
        fail_pipeline!(
          event: event,
          pipeline_state: pipeline_state,
          pipeline_run_id: pipeline_run_id,
          error: "pipeline_timeout waiting for parallel stage jobs"
        )
        return
      end

      waiting_on_steps = waiting_steps(pipeline_state: pipeline_state, run_id: pipeline_run_id)
      pipeline_state.touch_pipeline_heartbeat!(
        run_id: pipeline_run_id,
        active_job_id: job_id,
        step: "parallel_services",
        note: "Waiting for parallel stage workers to finish.",
        details: {
          waiting_on_steps: waiting_on_steps,
          attempts: attempts.to_i
        }
      )
      Ops::StructuredLogger.info(
        event: "llm_comment.pipeline.finalizer_waiting",
        payload: {
          event_id: event.id,
          instagram_profile_id: event.instagram_profile_id,
          pipeline_run_id: pipeline_run_id,
          active_job_id: job_id,
          attempts: attempts.to_i,
          waiting_on_steps: waiting_on_steps,
          waiting_step_rollup: waiting_step_rollup(
            pipeline_state: pipeline_state,
            run_id: pipeline_run_id,
            waiting_steps: waiting_on_steps
          )
        }
      )
      report_stage!(
        event: event,
        stage: "parallel_services",
        state: "running",
        progress: 36,
        message: "Parallel workers are still processing; waiting before final generation.",
        details: {
          pipeline_run_id: pipeline_run_id,
          waiting_on_steps: waiting_on_steps,
          attempts: attempts.to_i
        }
      )

      self.class.set(wait: poll_delay_seconds(attempts: attempts).seconds).perform_later(
        instagram_profile_event_id: event.id,
        pipeline_run_id: pipeline_run_id,
        provider: provider,
        model: model,
        requested_by: requested_by,
        attempts: attempts.to_i + 1
      )
      return
    end

    acquired = pipeline_state.mark_generation_started!(
      run_id: pipeline_run_id,
      active_job_id: job_id
    )
    return unless acquired

    generation_job = GenerateStoryCommentFromPipelineJob.perform_later(
      instagram_profile_event_id: event.id,
      pipeline_run_id: pipeline_run_id,
      provider: provider,
      model: model,
      requested_by: requested_by
    )

    report_stage!(
      event: event,
      stage: "parallel_services",
      state: "completed",
      progress: 40,
      message: "Parallel analysis jobs completed.",
      details: {
        pipeline_run_id: pipeline_run_id
      }
    )
    report_stage!(
      event: event,
      stage: "context_matching",
      state: "queued",
      progress: 42,
      message: "Queued LLM generation worker.",
      details: {
        pipeline_run_id: pipeline_run_id,
        generation_job_id: generation_job&.job_id.to_s.presence
      }.compact
    )

    Ops::StructuredLogger.info(
      event: "llm_comment.pipeline.generation_worker_queued",
      payload: {
        event_id: event.id,
        instagram_profile_id: event.instagram_profile_id,
        pipeline_run_id: pipeline_run_id,
        active_job_id: job_id,
        generation_job_id: generation_job&.job_id.to_s.presence,
        generation_queue_name: generation_job&.queue_name.to_s.presence,
        provider: provider,
        model: model,
        requested_by: requested_by
      }.compact
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

  def waiting_steps(pipeline_state:, run_id:)
    LlmComment::ParallelPipelineState::STEP_KEYS.select do |step|
      !pipeline_state.step_terminal?(run_id: run_id, step: step)
    end
  rescue StandardError
    []
  end

  def waiting_step_rollup(pipeline_state:, run_id:, waiting_steps:)
    step_rollup = pipeline_step_rollup(pipeline_state: pipeline_state, run_id: run_id)
    keys = Array(waiting_steps).map(&:to_s)
    keys.each_with_object({}) do |key, out|
      next unless step_rollup[key].is_a?(Hash)

      out[key] = step_rollup[key]
    end
  rescue StandardError
    {}
  end

  def poll_delay_seconds(attempts:)
    value = attempts.to_i
    return 3 if value < 4
    return 5 if value < 12
    return 8 if value < 24

    12
  end
end
