# frozen_string_literal: true

class ProcessStoryCommentFaceJob < StoryCommentStepJob
  queue_as Ops::AiServiceQueueRegistry.queue_symbol_for(:face_analysis)

  # Phase 4.5: legacy face recognition is soft-deprecated. The step
  # still needs to run so the story-comment pipeline state machine
  # completes, but we short-circuit to a "skipped" payload rather than
  # invoking the dropped microservice. Set LEGACY_AI_PIPELINE_ENABLED=true
  # to re-run the original face pipeline.
  def perform(instagram_profile_event_id:, pipeline_run_id:, provider: "local", model: nil, requested_by: "system")
    return super if Ai::LegacyPipelineConfig.enabled?

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
      run_id: pipeline_run_id, step: step_key,
      queue_name: queue_name, active_job_id: job_id
    )
    summary = {
      source: "legacy_pipeline_disabled",
      face_count: 0,
      people_count: 0,
      skipped: true,
      reason: "legacy_pipeline_disabled"
    }
    pipeline_state.mark_step_completed!(
      run_id: pipeline_run_id,
      step: step_key,
      summary: summary
    )
    report_stage!(
      event: event,
      stage: step_key,
      state: "skipped",
      progress: step_progress(step_key, :completed),
      message: "Legacy face pipeline disabled (Phase 4.5); skipping.",
      details: { pipeline_run_id: pipeline_run_id, summary: summary }
    )
  end

  private

  def step_key
    "face_recognition"
  end

  def running_message
    "Face detection started."
  end

  def failed_message
    "Face detection failed."
  end

  def failure_reason
    "face_stage_failed"
  end

  def completed_message(summary:)
    summary[:face_count].to_i.positive? ? "Face detection completed." : "Face detection completed with no faces."
  end

  def extract_summary(payload:, event:, context:)
    face_count = payload[:face_count].to_i
    people = Array(payload[:people]).select { |row| row.is_a?(Hash) }.first(12)

    {
      source: payload[:source].to_s.presence,
      face_count: face_count,
      people_count: people.length
    }
  end

  def completion_details(summary:)
    {
      face_count: summary[:face_count],
      people_count: summary[:people_count]
    }
  end

  def allows_terminal_pipeline_processing?(context:)
    context.dig(:pipeline, "status").to_s == "completed"
  end

  def enqueue_finalizer_after_step?
    false
  end
end
