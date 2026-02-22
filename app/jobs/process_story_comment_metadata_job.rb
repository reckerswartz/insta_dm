# frozen_string_literal: true

class ProcessStoryCommentMetadataJob < StoryCommentStepJob
  queue_as Ops::AiServiceQueueRegistry.queue_symbol_for(:metadata_tagging)

  private

  def step_key
    "metadata_extraction"
  end

  def running_message
    "Metadata extraction started."
  end

  def failed_message
    "Metadata extraction failed."
  end

  def failure_reason
    "metadata_stage_failed"
  end

  def completed_message(summary:)
    "Metadata extraction completed."
  end

  def fetch_step_payload(event:, pipeline_state:, pipeline_run_id:)
    {}
  end

  def extract_summary(payload:, event:, context:)
    metadata = event.metadata.is_a?(Hash) ? event.metadata : {}
    blob = event.media.attached? ? event.media.blob : nil
    {
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
  end

  def completion_details(summary:)
    {
      media_content_type: summary[:media_content_type],
      media_bytes: summary[:media_bytes]
    }
  end

  def completion_log_payload(summary:)
    {
      media_content_type: summary[:media_content_type],
      media_bytes: summary[:media_bytes]
    }
  end
end
