# frozen_string_literal: true

class StoryCommentPipelineJob < ApplicationJob
  private

  def load_story_pipeline_context!(instagram_profile_event_id:, pipeline_run_id:)
    event = InstagramProfileEvent.find(instagram_profile_event_id)
    return nil unless event.story_archive_item?

    pipeline_state = LlmComment::ParallelPipelineState.new(event: event)
    pipeline = pipeline_state.pipeline_for(run_id: pipeline_run_id)
    return nil unless pipeline

    {
      event: event,
      pipeline_state: pipeline_state,
      pipeline: pipeline
    }
  rescue ActiveRecord::RecordNotFound
    nil
  end

  def report_stage!(event:, stage:, state:, progress:, message:, details: nil)
    stages = event.record_llm_processing_stage!(
      stage: stage,
      state: state,
      progress: progress,
      message: message,
      details: details
    )

    event.broadcast_llm_comment_generation_progress(
      stage: stage,
      message: message,
      progress: progress,
      details: details,
      stage_statuses: stages
    )
  rescue StandardError
    nil
  end

  def enqueue_pipeline_finalizer(event:, pipeline_run_id:, provider:, model:, requested_by:, attempts: 0)
    job = FinalizeStoryCommentPipelineJob.perform_later(
      instagram_profile_event_id: event.id,
      pipeline_run_id: pipeline_run_id,
      provider: provider,
      model: model,
      requested_by: requested_by,
      attempts: attempts
    )
    Ops::StructuredLogger.info(
      event: "llm_comment.pipeline.finalizer_enqueued",
      payload: {
        event_id: event.id,
        instagram_profile_id: event.instagram_profile_id,
        pipeline_run_id: pipeline_run_id,
        provider: provider,
        model: model,
        requested_by: requested_by,
        attempts: attempts.to_i,
        finalizer_job_id: job&.job_id.to_s.presence,
        finalizer_queue_name: job&.queue_name.to_s.presence
      }.compact
    )
    job
  rescue StandardError
    nil
  end

  def enqueue_pipeline_finalizer_if_ready(context:, pipeline_run_id:, provider:, model:, requested_by:)
    pipeline_state = context[:pipeline_state]
    return unless pipeline_state.all_steps_terminal?(run_id: pipeline_run_id)

    enqueue_pipeline_finalizer(
      event: context[:event],
      pipeline_run_id: pipeline_run_id,
      provider: provider,
      model: model,
      requested_by: requested_by
    )
  rescue StandardError
    nil
  end

  def step_progress(step, state)
    LlmComment::StepRegistry.progress_for(step: step, state: state)
  end

  def truncated_error(error)
    "#{error.class}: #{error.message}".byteslice(0, 320)
  end

  def normalize_hash(value)
    value.is_a?(Hash) ? value.deep_symbolize_keys : {}
  rescue StandardError
    {}
  end

  def step_timing_metrics(pipeline_state:, run_id:, step:)
    row = pipeline_state.step_state(run_id: run_id, step: step)
    return {} unless row.is_a?(Hash)

    {
      queue_wait_ms: row["queue_wait_ms"],
      run_duration_ms: row["run_duration_ms"],
      total_duration_ms: row["total_duration_ms"],
      attempts: row["attempts"].to_i,
      queued_at: row["queued_at"].to_s.presence || row["created_at"].to_s.presence,
      started_at: row["started_at"].to_s.presence,
      finished_at: row["finished_at"].to_s.presence
    }.compact
  rescue StandardError
    {}
  end

  def pipeline_step_rollup(pipeline_state:, run_id:)
    value = pipeline_state.step_rollup(run_id: run_id)
    value.is_a?(Hash) ? value : {}
  rescue StandardError
    {}
  end

  def pipeline_timing_rollup(pipeline_state:, run_id:)
    value = pipeline_state.pipeline_timing(run_id: run_id)
    value.is_a?(Hash) ? value : {}
  rescue StandardError
    {}
  end

  def with_pipeline_heartbeat(event:, pipeline_state:, pipeline_run_id:, step:, message:, interval_seconds: 20, progress: nil, details: nil)
    stop = false
    heartbeat = Thread.new do
      Thread.current.abort_on_exception = false
      until stop
        sleep interval_seconds
        break if stop

        pipeline_state.touch_pipeline_heartbeat!(
          run_id: pipeline_run_id,
          active_job_id: job_id,
          step: step,
          note: message,
          details: details
        )
        report_stage!(
          event: event,
          stage: step,
          state: "running",
          progress: progress || step_progress(step, :running),
          message: message,
          details: (details || {}).merge(pipeline_run_id: pipeline_run_id, heartbeat: true)
        )
        Ops::StructuredLogger.info(
          event: "llm_comment.pipeline.heartbeat",
          payload: {
            event_id: event.id,
            instagram_profile_id: event.instagram_profile_id,
            pipeline_run_id: pipeline_run_id,
            step: step,
            active_job_id: job_id,
            queue_name: queue_name,
            note: message
          }
        )
      end
    rescue StandardError
      nil
    end

    yield
  ensure
    stop = true
    heartbeat&.join(0.25)
  end
end
