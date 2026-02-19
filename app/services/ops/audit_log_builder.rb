module Ops
  class AuditLogBuilder
    class << self
      def for_account(instagram_account:, limit: 120)
        account = instagram_account
        cap = limit.to_i.clamp(1, 500)

        action_logs =
          account.instagram_profile_action_logs
            .includes(:instagram_profile)
            .order(occurred_at: :desc, id: :desc)
            .limit(cap)
            .map do |log|
              metadata = log.metadata.is_a?(Hash) ? log.metadata : {}
              {
                type: "action",
                occurred_at: log.occurred_at || log.created_at,
                profile_id: log.instagram_profile&.id,
                profile_username: log.instagram_profile&.username,
                kind: log.action.to_s,
                status: log.status.to_s,
                detail: log.log_text.to_s.presence || log.error_message.to_s.presence || metadata.to_s.byteslice(0, 180),
                comment_text: metadata["comment_text"].to_s.presence || metadata["ai_reply_text"].to_s.presence || metadata["posted_comment"].to_s.presence
              }
            end

        events =
          InstagramProfileEvent
            .joins(:instagram_profile)
            .where(instagram_profiles: { instagram_account_id: account.id })
            .includes(:instagram_profile, media_attachment: :blob, preview_image_attachment: :blob)
            .order(detected_at: :desc, id: :desc)
            .limit(cap)
            .map do |event|
              metadata = event.metadata.is_a?(Hash) ? event.metadata : {}
              media_attached = event.media.attached?
              {
                type: "event",
                occurred_at: event.occurred_at || event.detected_at || event.created_at,
                profile_id: event.instagram_profile&.id,
                profile_username: event.instagram_profile&.username,
                kind: event.kind.to_s,
                status: "recorded",
                detail: metadata.to_s.byteslice(0, 180),
                comment_text: metadata["comment_text"].to_s.presence || metadata["ai_reply_text"].to_s.presence || metadata["posted_comment"].to_s.presence,
                media_attached: media_attached,
                media_url: media_attached ? Rails.application.routes.url_helpers.rails_blob_path(event.media, only_path: true) : nil,
                media_download_url: media_attached ? Rails.application.routes.url_helpers.rails_blob_path(event.media, disposition: "attachment", only_path: true) : nil,
                media_content_type: media_attached ? event.media.blob&.content_type.to_s : nil,
                media_preview_image_url: preferred_video_preview_image_url(event: event, metadata: metadata),
                video_static_frame_only: static_video_preview?(metadata: metadata)
              }
            end

        (action_logs + events)
          .sort_by { |e| e[:occurred_at] || Time.at(0) }
          .reverse
          .first(cap)
      end

      private

      def static_video_preview?(metadata:)
        data = metadata.is_a?(Hash) ? metadata : {}
        processing = data["processing_metadata"].is_a?(Hash) ? data["processing_metadata"] : {}
        frame_change = processing["frame_change_detection"].is_a?(Hash) ? processing["frame_change_detection"] : {}
        local_intel = data["local_story_intelligence"].is_a?(Hash) ? data["local_story_intelligence"] : {}

        processing["source"].to_s == "video_static_single_frame" ||
          frame_change["processing_mode"].to_s == "static_image" ||
          local_intel["video_processing_mode"].to_s == "static_image"
      end

      def preferred_video_preview_image_url(event:, metadata:)
        if event.preview_image.attached?
          return Rails.application.routes.url_helpers.rails_blob_path(event.preview_image, only_path: true)
        end

        data = metadata.is_a?(Hash) ? metadata : {}
        direct = data["image_url"].to_s.presence
        return direct if direct.present?

        variants = Array(data["carousel_media"])
        candidate = variants.find { |entry| entry.is_a?(Hash) && entry["image_url"].to_s.present? }
        candidate.is_a?(Hash) ? candidate["image_url"].to_s.presence : nil
      end
    end
  end
end
