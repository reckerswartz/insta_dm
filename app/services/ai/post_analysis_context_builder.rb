require "base64"
require "digest"
require "uri"

module Ai
  class PostAnalysisContextBuilder
    MAX_INLINE_IMAGE_BYTES = ENV.fetch("AI_MAX_INLINE_IMAGE_BYTES", 2 * 1024 * 1024).to_i
    MAX_INLINE_VIDEO_BYTES = ENV.fetch("AI_MAX_INLINE_VIDEO_BYTES", 12 * 1024 * 1024).to_i
    MAX_VIDEO_FRAME_ANALYSIS_BYTES = ENV.fetch("AI_VIDEO_FRAME_MAX_BYTES", 35 * 1024 * 1024).to_i

    def initialize(profile:, post:)
      @profile = profile
      @post = post
    end

    attr_reader :profile, :post

    def payload
      {
        post: {
          shortcode: post.shortcode,
          caption: post.caption,
          taken_at: post.taken_at&.iso8601,
          permalink: post.permalink_url,
          likes_count: post.likes_count,
          comments_count: post.comments_count,
          comments: post.instagram_profile_post_comments.recent_first.limit(25).map do |comment|
            {
              author_username: comment.author_username,
              body: comment.body,
              commented_at: comment.commented_at&.iso8601
            }
          end
        },
        author_profile: {
          username: profile.username,
          display_name: profile.display_name,
          bio: profile.bio,
          can_message: profile.can_message,
          tags: profile.profile_tags.pluck(:name).sort
        },
        rules: {
          require_manual_review: true,
          style: "gen_z_light"
        }
      }
    end

    def media_payload
      return { type: "none" } unless post.media.attached?

      blob = post.media.blob
      return { type: "none" } unless blob

      content_type = blob.content_type.to_s
      is_image = content_type.start_with?("image/")
      is_video = content_type.start_with?("video/")
      return { type: "none" } unless is_image || is_video

      if is_image && blob.byte_size.to_i > MAX_INLINE_IMAGE_BYTES
        media_url = post.source_media_url.to_s
        return { type: "image", content_type: content_type, url: media_url } if media_url.present?
      elsif is_video && blob.byte_size.to_i > MAX_INLINE_VIDEO_BYTES
        media_url = post.source_media_url.to_s
        return { type: "video", content_type: content_type, url: media_url } if media_url.present?
      end

      data = blob.download
      payload = {
        type: is_video ? "video" : "image",
        content_type: content_type,
        bytes: data
      }
      if is_image
        encoded = Base64.strict_encode64(data)
        payload[:image_data_url] = "data:#{content_type};base64,#{encoded}"
      end
      payload
    rescue StandardError
      { type: "none" }
    end

    def media_fingerprint(media: nil)
      fingerprint = post.media_url_fingerprint.to_s
      return fingerprint if fingerprint.present?

      if post.media.attached?
        checksum = post.media.blob&.checksum.to_s
        return "blob:#{checksum}" if checksum.present?
      end

      normalized_url = normalize_url(post.source_media_url)
      return Digest::SHA256.hexdigest(normalized_url) if normalized_url.present?

      payload = media || media_payload
      bytes = payload[:bytes]
      return Digest::SHA256.hexdigest(bytes) if bytes.present?

      nil
    end

    def detection_image_payload
      return { skipped: true, reason: "media_missing" } unless post.media.attached?

      content_type = post.media.blob&.content_type.to_s
      if content_type.start_with?("image/")
        return {
          skipped: false,
          image_bytes: post.media.download,
          detection_source: "post_media_image",
          content_type: content_type
        }
      end

      if content_type.start_with?("video/")
        if post.preview_image.attached?
          return {
            skipped: false,
            image_bytes: post.preview_image.download,
            detection_source: "post_preview_image",
            content_type: post.preview_image.blob&.content_type.to_s
          }
        end

        begin
          generated_preview = post.media.preview(resize_to_limit: [ 960, 960 ]).processed
          preview_blob = generated_preview.respond_to?(:image) ? generated_preview.image : nil
          return {
            skipped: false,
            image_bytes: generated_preview.download,
            detection_source: "post_generated_video_preview",
            content_type: preview_blob&.content_type.to_s.presence || "image/jpeg"
          }
        rescue StandardError
          return {
            skipped: true,
            reason: "video_preview_unavailable",
            content_type: content_type
          }
        end
      end

      {
        skipped: true,
        reason: "unsupported_content_type",
        content_type: content_type
      }
    rescue StandardError => e
      {
        skipped: true,
        reason: "media_load_error",
        error: e.message.to_s,
        content_type: content_type.to_s
      }
    end

    def video_payload
      return { skipped: true, reason: "media_missing" } unless post.media.attached?

      blob = post.media.blob
      content_type = blob&.content_type.to_s
      return { skipped: true, reason: "not_video", content_type: content_type } unless content_type.to_s.start_with?("video/")

      if blob.byte_size.to_i > MAX_VIDEO_FRAME_ANALYSIS_BYTES
        return {
          skipped: true,
          reason: "video_too_large_for_frame_analysis",
          content_type: content_type,
          byte_size: blob.byte_size.to_i,
          max_bytes: MAX_VIDEO_FRAME_ANALYSIS_BYTES
        }
      end

      {
        skipped: false,
        video_bytes: blob.download,
        content_type: content_type,
        reference_id: "post_media_#{post.id}"
      }
    rescue StandardError => e
      {
        skipped: true,
        reason: "video_load_error",
        error: e.message.to_s
      }
    end

    private

    def normalize_url(raw)
      value = raw.to_s.strip
      return nil if value.blank?

      uri = URI.parse(value)
      return value unless uri.is_a?(URI::HTTP) || uri.is_a?(URI::HTTPS)

      "#{uri.scheme}://#{uri.host}#{uri.path}"
    rescue StandardError
      value
    end
  end
end
