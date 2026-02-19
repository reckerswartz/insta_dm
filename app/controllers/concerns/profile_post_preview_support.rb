module ProfilePostPreviewSupport
  extend ActiveSupport::Concern

  PROFILE_POST_PREVIEW_ENQUEUE_TTL_SECONDS = 30.minutes

  included do
    helper_method :preferred_profile_post_preview_image_url
  end

  private

  def preferred_profile_post_preview_image_url(post:, metadata:)
    if post.preview_image.attached?
      return Rails.application.routes.url_helpers.rails_blob_path(post.preview_image, only_path: true)
    end

    data = metadata.is_a?(Hash) ? metadata : {}
    direct_url = [
      data["preview_image_url"],
      data["poster_url"],
      data["image_url"],
      data["media_url_image"]
    ].find(&:present?)
    return direct_url.to_s if direct_url.present?

    local_profile_post_preview_representation_url(post: post)
  end

  def local_profile_post_preview_representation_url(post:)
    return nil unless post.media.attached?
    return nil unless post.media.blob&.content_type.to_s.start_with?("video/")

    enqueue_profile_post_preview_generation(post: post)
    view_context.url_for(post.media.preview(resize_to_limit: [ 640, 640 ]))
  rescue StandardError
    nil
  end

  def enqueue_profile_post_preview_generation(post:)
    return if post.preview_image.attached?

    cache_key = "profile_post:preview_enqueue:#{post.id}"
    Rails.cache.fetch(cache_key, expires_in: PROFILE_POST_PREVIEW_ENQUEUE_TTL_SECONDS) do
      GenerateProfilePostPreviewImageJob.perform_later(instagram_profile_post_id: post.id)
      true
    end
  rescue StandardError => e
    Rails.logger.warn("[profile_post_preview] preview enqueue failed post_id=#{post.id}: #{e.class}: #{e.message}")
    nil
  end
end
