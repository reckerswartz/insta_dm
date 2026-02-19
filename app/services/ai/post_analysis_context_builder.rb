require "base64"
require "digest"
require "uri"

module Ai
  class PostAnalysisContextBuilder
    MAX_INLINE_IMAGE_BYTES = ENV.fetch("AI_MAX_INLINE_IMAGE_BYTES", 2 * 1024 * 1024).to_i
    MAX_INLINE_VIDEO_BYTES = ENV.fetch("AI_MAX_INLINE_VIDEO_BYTES", 12 * 1024 * 1024).to_i
    MAX_DIRECT_IMAGE_ANALYSIS_BYTES = ENV.fetch("AI_MAX_DIRECT_IMAGE_ANALYSIS_BYTES", 10 * 1024 * 1024).to_i
    MAX_DIRECT_VIDEO_ANALYSIS_BYTES = ENV.fetch("AI_MAX_DIRECT_VIDEO_ANALYSIS_BYTES", 40 * 1024 * 1024).to_i
    MAX_ABSOLUTE_MEDIA_BYTES = ENV.fetch("AI_MAX_ABSOLUTE_MEDIA_BYTES", 120 * 1024 * 1024).to_i
    MIN_MEDIA_BYTES = ENV.fetch("AI_MIN_MEDIA_BYTES", 512).to_i
    IMAGE_RESIZE_MAX_DIMENSION = ENV.fetch("AI_IMAGE_RESIZE_MAX_DIMENSION", 1920).to_i
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
      return none_media_payload(reason: "media_missing") unless post.media.attached?

      blob = post.media.blob
      return none_media_payload(reason: "media_blob_missing") unless blob

      content_type = blob.content_type.to_s
      byte_size = blob.byte_size.to_i
      is_image = content_type.start_with?("image/")
      is_video = content_type.start_with?("video/")
      return none_media_payload(reason: "unsupported_content_type", content_type: content_type) unless is_image || is_video
      return none_media_payload(reason: "zero_byte_blob", content_type: content_type, byte_size: byte_size) if byte_size <= 0
      return none_media_payload(reason: "media_too_large", content_type: content_type, byte_size: byte_size, max_bytes: MAX_ABSOLUTE_MEDIA_BYTES) if byte_size > MAX_ABSOLUTE_MEDIA_BYTES

      media_type = is_video ? "video" : "image"
      media_url = normalize_url(post.source_media_url)
      if is_image && byte_size > MAX_INLINE_IMAGE_BYTES && media_url.present?
        return url_media_payload(type: media_type, content_type: content_type, url: media_url, byte_size: byte_size)
      end
      if is_video && byte_size > MAX_INLINE_VIDEO_BYTES && media_url.present?
        return url_media_payload(type: media_type, content_type: content_type, url: media_url, byte_size: byte_size)
      end
      if is_video && byte_size > MAX_DIRECT_VIDEO_ANALYSIS_BYTES
        return none_media_payload(
          reason: "video_too_large_for_direct_analysis",
          content_type: content_type,
          byte_size: byte_size,
          max_bytes: MAX_DIRECT_VIDEO_ANALYSIS_BYTES
        )
      end

      data =
        if is_image && byte_size > MAX_DIRECT_IMAGE_ANALYSIS_BYTES
          resize_image_blob(blob: blob)
        else
          blob.download
        end

      data = data.to_s.b
      return none_media_payload(reason: "media_bytes_missing", content_type: content_type, byte_size: byte_size) if data.blank?
      return none_media_payload(reason: "media_bytes_too_small", content_type: content_type, byte_size: data.bytesize, min_bytes: MIN_MEDIA_BYTES) if data.bytesize < MIN_MEDIA_BYTES
      return none_media_payload(reason: "media_signature_invalid", content_type: content_type, byte_size: data.bytesize) unless valid_signature?(content_type: content_type, bytes: data)

      payload = {
        type: media_type,
        content_type: content_type,
        bytes: data,
        source: (is_image && byte_size > MAX_DIRECT_IMAGE_ANALYSIS_BYTES) ? "resized_blob" : "blob",
        byte_size: data.bytesize
      }
      if is_image && data.bytesize <= MAX_INLINE_IMAGE_BYTES
        encoded = Base64.strict_encode64(data)
        payload[:image_data_url] = "data:#{content_type};base64,#{encoded}"
      end
      payload
    rescue StandardError => e
      none_media_payload(
        reason: "media_payload_error",
        content_type: blob&.content_type.to_s,
        byte_size: blob&.byte_size.to_i,
        error: "#{e.class}: #{e.message}"
      )
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

    def url_media_payload(type:, content_type:, url:, byte_size:)
      {
        type: type.to_s,
        content_type: content_type.to_s,
        url: url.to_s,
        source: "source_media_url",
        byte_size: byte_size.to_i
      }
    end

    def none_media_payload(reason:, content_type: nil, byte_size: nil, max_bytes: nil, min_bytes: nil, error: nil)
      {
        type: "none",
        reason: reason.to_s,
        content_type: content_type.to_s.presence,
        byte_size: byte_size,
        max_bytes: max_bytes,
        min_bytes: min_bytes,
        error: error.to_s.presence
      }.compact
    end

    def resize_image_blob(blob:)
      variant = post.media.variant(resize_to_limit: [ IMAGE_RESIZE_MAX_DIMENSION, IMAGE_RESIZE_MAX_DIMENSION ])
      variant.processed.download
    rescue StandardError
      blob.download
    end

    def valid_signature?(content_type:, bytes:)
      type = content_type.to_s.downcase
      return false if bytes.blank?

      if type.include?("jpeg")
        return bytes.start_with?("\xFF\xD8".b)
      end
      if type.include?("png")
        return bytes.start_with?("\x89PNG\r\n\x1A\n".b)
      end
      if type.include?("gif")
        return bytes.start_with?("GIF87a".b) || bytes.start_with?("GIF89a".b)
      end
      if type.include?("webp")
        return bytes.bytesize >= 12 && bytes.byteslice(0, 4) == "RIFF" && bytes.byteslice(8, 4) == "WEBP"
      end
      if type.include?("heic") || type.include?("heif")
        return bytes.bytesize >= 12 && bytes.byteslice(4, 4) == "ftyp"
      end
      if type.start_with?("video/")
        return bytes.bytesize >= 12 && bytes.byteslice(4, 4) == "ftyp" if type.include?("mp4") || type.include?("quicktime")
        return bytes.bytesize >= 4 && bytes.byteslice(0, 4) == "\x1A\x45\xDF\xA3".b if type.include?("webm")
      end

      true
    end

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
