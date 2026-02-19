class GenerateProfilePostPreviewImageJob < ApplicationJob
  queue_as :frame_generation

  retry_on ActiveStorage::PreviewError, wait: :polynomially_longer, attempts: 3
  retry_on StandardError, wait: 10.seconds, attempts: 2

  def perform(instagram_profile_post_id:)
    post = InstagramProfilePost.find_by(id: instagram_profile_post_id)
    return unless post&.media&.attached?
    return if post.preview_image.attached?
    return unless post.media.blob&.content_type.to_s.start_with?("video/")

    preview = post.media.preview(resize_to_limit: [ 640, 640 ]).processed
    preview_image = preview.image
    return unless preview_image&.attached?

    post.with_lock do
      return if post.preview_image.attached?

      post.preview_image.attach(preview_image.blob)
      metadata = post.metadata.is_a?(Hash) ? post.metadata.deep_dup : {}
      post.update!(
        metadata: metadata.merge(
          "preview_image_status" => "attached",
          "preview_image_source" => "active_storage_preview_job",
          "preview_image_attached_at" => Time.current.utc.iso8601(3)
        )
      )
    end

    Rails.logger.info("[GenerateProfilePostPreviewImageJob] attached preview_image post_id=#{post.id} blob_id=#{preview_image.blob.id}")
  rescue StandardError => e
    Rails.logger.warn("[GenerateProfilePostPreviewImageJob] failed post_id=#{instagram_profile_post_id}: #{e.class}: #{e.message}")
    raise
  end
end
