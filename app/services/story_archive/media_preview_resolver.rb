module StoryArchive
  class MediaPreviewResolver
    class << self
      def static_video_preview?(metadata:)
        data = metadata_hash(metadata)
        processing = metadata_hash(data["processing_metadata"])
        frame_change = metadata_hash(processing["frame_change_detection"])
        local_intelligence = metadata_hash(data["local_story_intelligence"])

        processing["source"].to_s == "video_static_single_frame" ||
          frame_change["processing_mode"].to_s == "static_image" ||
          local_intelligence["video_processing_mode"].to_s == "static_image"
      end

      def preferred_preview_image_url(event:, metadata:)
        preview_image_path(event) || metadata_preview_image_url(metadata: metadata)
      end

      def metadata_preview_image_url(metadata:)
        data = metadata_hash(metadata)
        direct = data["image_url"].to_s.presence
        return direct if direct.present?

        variants = Array(data["carousel_media"])
        candidate = variants.find { |entry| entry.is_a?(Hash) && entry["image_url"].to_s.present? }
        candidate.is_a?(Hash) ? candidate["image_url"].to_s.presence : nil
      end

      private

      def preview_image_path(event)
        return nil unless event.respond_to?(:preview_image)
        return nil unless event.preview_image.attached?

        Rails.application.routes.url_helpers.rails_blob_path(event.preview_image, only_path: true)
      rescue StandardError
        nil
      end

      def metadata_hash(value)
        value.is_a?(Hash) ? value : {}
      end
    end
  end
end
