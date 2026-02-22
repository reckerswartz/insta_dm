# frozen_string_literal: true

module StoryPipelineFailureHandling
  private

  def fail_story_pipeline!(event:, pipeline_state:, pipeline_run_id:, error:, active_job_id: nil)
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
