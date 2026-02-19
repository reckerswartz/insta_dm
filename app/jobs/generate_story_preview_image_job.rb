class GenerateStoryPreviewImageJob < ApplicationJob
  queue_as :frame_generation

  retry_on ActiveStorage::PreviewError, wait: :polynomially_longer, attempts: 3
  retry_on StandardError, wait: 10.seconds, attempts: 2

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
    end

    Rails.logger.info("[GenerateStoryPreviewImageJob] attached preview_image event_id=#{event.id} blob_id=#{preview_image.blob.id}")
  rescue StandardError => e
    Rails.logger.warn("[GenerateStoryPreviewImageJob] failed event_id=#{instagram_profile_event_id}: #{e.class}: #{e.message}")
    raise
  end
end
