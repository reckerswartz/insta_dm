class GenerateStoryPreviewImageJob < ApplicationJob
  queue_as :frame_generation

  retry_on ActiveStorage::PreviewError, wait: :polynomially_longer, attempts: 3
  retry_on StandardError, wait: 10.seconds, attempts: 2
  NON_RETRYABLE_PREVIEW_PATTERNS = [
    "invalid data found when processing input",
    "error reading header",
    "could not find corresponding trex",
    "trun track id unknown",
    "no tfhd was found",
    "moov atom not found"
  ].freeze

  def perform(instagram_profile_event_id:)
    event = InstagramProfileEvent.find_by(id: instagram_profile_event_id)
    return unless event&.media&.attached?
    return if event.preview_image.attached?
    return unless event.media.blob&.content_type.to_s.start_with?("video/")

    preview = event.media.preview(resize_to_limit: [640, 640]).processed
    preview_image = preview.image
    return unless preview_image&.attached?

    event.with_lock do
      return if event.preview_image.attached?

      event.preview_image.attach(preview_image.blob)
      stamp_preview_success_metadata!(event: event)
    end

    Rails.logger.info("[GenerateStoryPreviewImageJob] attached preview_image event_id=#{event.id} blob_id=#{preview_image.blob.id}")
  rescue ActiveStorage::PreviewError => e
    if event && non_retryable_preview_error?(e)
      stamp_preview_failure_metadata!(
        event: event,
        reason: "invalid_video_stream",
        detail: e.message
      )
      Rails.logger.warn(
        "[GenerateStoryPreviewImageJob] non-retryable preview failure event_id=#{instagram_profile_event_id}: " \
        "#{e.class}: #{e.message}"
      )
      return
    end

    Rails.logger.warn("[GenerateStoryPreviewImageJob] failed event_id=#{instagram_profile_event_id}: #{e.class}: #{e.message}")
    raise
  rescue StandardError => e
    Rails.logger.warn("[GenerateStoryPreviewImageJob] failed event_id=#{instagram_profile_event_id}: #{e.class}: #{e.message}")
    raise
  end

  private

  def non_retryable_preview_error?(error)
    message = error.to_s.downcase
    NON_RETRYABLE_PREVIEW_PATTERNS.any? { |pattern| message.include?(pattern) }
  end

  def stamp_preview_success_metadata!(event:)
    metadata = event.metadata.is_a?(Hash) ? event.metadata.deep_dup : {}
    metadata["preview_image_status"] = "attached"
    metadata["preview_image_source"] = "active_storage_preview_job"
    metadata["preview_image_attached_at"] = Time.current.utc.iso8601(3)
    metadata.delete("preview_image_failed_at")
    metadata.delete("preview_image_failure_reason")
    metadata.delete("preview_image_failure_detail")
    event.update!(metadata: metadata)
  rescue StandardError
    nil
  end

  def stamp_preview_failure_metadata!(event:, reason:, detail:)
    metadata = event.metadata.is_a?(Hash) ? event.metadata.deep_dup : {}
    metadata["preview_image_status"] = "failed"
    metadata["preview_image_source"] = "active_storage_preview_job"
    metadata["preview_image_failed_at"] = Time.current.utc.iso8601(3)
    metadata["preview_image_failure_reason"] = reason.to_s
    snippet = detail.to_s.strip.byteslice(0, 500)
    metadata["preview_image_failure_detail"] = snippet if snippet.present?
    event.update!(metadata: metadata)
  rescue StandardError
    nil
  end
end
