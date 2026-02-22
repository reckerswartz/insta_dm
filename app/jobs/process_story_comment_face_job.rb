# frozen_string_literal: true

class ProcessStoryCommentFaceJob < StoryCommentStepJob
  queue_as Ops::AiServiceQueueRegistry.queue_symbol_for(:face_analysis)

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
