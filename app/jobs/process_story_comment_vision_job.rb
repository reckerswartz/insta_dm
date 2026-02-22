# frozen_string_literal: true

class ProcessStoryCommentVisionJob < StoryCommentStepJob
  queue_as Ops::AiServiceQueueRegistry.queue_symbol_for(:visual_analysis)

  private

  def step_key
    "vision_detection"
  end

  def running_message
    "Region and vision detection started."
  end

  def failed_message
    "Region and vision detection failed."
  end

  def failure_reason
    "vision_stage_failed"
  end

  def completed_message(summary:)
    "Region and vision detection completed."
  end

  def extract_summary(payload:, event:, context:)
    object_detections = Array(payload[:object_detections]).select { |row| row.is_a?(Hash) }.first(120)
    scenes = Array(payload[:scenes]).select { |row| row.is_a?(Hash) }.first(80)
    objects = Array(payload[:objects]).map(&:to_s).reject(&:blank?).uniq.first(40)
    topics = Array(payload[:topics]).map(&:to_s).reject(&:blank?).uniq.first(40)

    {
      source: payload[:source].to_s.presence,
      objects_count: objects.length,
      object_detections_count: object_detections.length,
      scenes_count: scenes.length,
      topics_count: topics.length
    }
  end

  def completion_details(summary:)
    {
      objects_count: summary[:objects_count],
      object_detections_count: summary[:object_detections_count],
      scenes_count: summary[:scenes_count]
    }
  end
end
