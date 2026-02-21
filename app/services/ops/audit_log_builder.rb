module Ops
  class AuditLogBuilder
    SKIP_EVENT_KINDS = %w[story_reply_skipped story_sync_failed story_sync_job_failed story_ad_skipped].freeze

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
              media = resolve_event_media(event: event, metadata: metadata)
              skip_reason = extract_skip_reason(kind: event.kind.to_s, metadata: metadata)
              {
                type: "event",
                occurred_at: event.occurred_at || event.detected_at || event.created_at,
                profile_id: event.instagram_profile&.id,
                profile_username: event.instagram_profile&.username,
                kind: event.kind.to_s,
                status: "recorded",
                detail: build_event_detail(kind: event.kind.to_s, metadata: metadata, skip_reason: skip_reason),
                skip_event: skip_reason.present?,
                skip_reason: skip_reason,
                comment_text: metadata["comment_text"].to_s.presence || metadata["ai_reply_text"].to_s.presence || metadata["posted_comment"].to_s.presence,
                media_attached: media[:available],
                media_modal_supported: media[:modal_supported],
                media_reference_url: media[:reference_url],
                media_url: media[:view_url],
                media_download_url: media[:download_url],
                media_content_type: media[:content_type],
                media_preview_image_url: media[:preview_url],
                video_static_frame_only: media[:video_static_frame_only]
              }
            end

        (action_logs + events)
          .sort_by { |e| e[:occurred_at] || Time.at(0) }
          .reverse
          .first(cap)
      end

      private

      def extract_skip_reason(kind:, metadata:)
        return nil unless SKIP_EVENT_KINDS.include?(kind.to_s)

        metadata["reason"].to_s.presence || metadata["skip_reason"].to_s.presence || kind.to_s
      end

      def build_event_detail(kind:, metadata:, skip_reason:)
        return metadata.to_s.byteslice(0, 180) if skip_reason.blank?

        prefix = %w[story_sync_failed story_sync_job_failed].include?(kind.to_s) ? "Failure reason" : "Skip reason"
        details = [ skip_reason.to_s ]
        status = metadata["status"].to_s.presence
        details << status if status.present?
        details << "quality=#{metadata["quality_reason"]}" if metadata["quality_reason"].present?
        details << "submission=#{metadata["submission_reason"]}" if metadata["submission_reason"].present?
        details << "api_status=#{metadata["api_failure_status"]}" if metadata["api_failure_status"].present?
        details << "api_endpoint=#{metadata["api_failure_endpoint"]}" if metadata["api_failure_endpoint"].present?
        details << "api_reason=#{metadata["api_failure_reason"]}" if metadata["api_failure_reason"].present?
        details << "api_useragent_mismatch=true" if ActiveModel::Type::Boolean.new.cast(metadata["api_useragent_mismatch"])
        details << "retryable=#{metadata["retryable"]}" if metadata.key?("retryable")
        details << "story_ref=#{metadata["story_ref"]}" if metadata["story_ref"].to_s.present?
        details << "media_source=#{metadata["media_source"]}" if metadata["media_source"].to_s.present?
        details << "error=#{metadata["error_class"]}" if metadata["error_class"].to_s.present?

        "#{prefix}: #{details.join(' | ')}".byteslice(0, 320)
      rescue StandardError
        metadata.to_s.byteslice(0, 180)
      end

      def resolve_event_media(event:, metadata:)
        if event.media.attached?
          blob_path = Rails.application.routes.url_helpers.rails_blob_path(event.media, only_path: true)
          return {
            available: true,
            modal_supported: true,
            reference_url: blob_path,
            view_url: blob_path,
            download_url: Rails.application.routes.url_helpers.rails_blob_path(event.media, disposition: "attachment", only_path: true),
            content_type: event.media.blob&.content_type.to_s.presence,
            preview_url: StoryArchive::MediaPreviewResolver.preferred_preview_image_url(event: event, metadata: metadata),
            video_static_frame_only: StoryArchive::MediaPreviewResolver.static_video_preview?(metadata: metadata)
          }
        end

        reference_url = first_present(
          metadata["media_url"],
          metadata["image_url"],
          metadata["video_url"],
          metadata["story_url"],
          metadata["permalink"],
          metadata["linked_profile_url"]
        )
        download_url = first_present(
          metadata["media_url"],
          metadata["video_url"],
          metadata["image_url"],
          reference_url
        )
        content_type = infer_content_type(url: first_present(metadata["media_url"], reference_url), metadata: metadata)
        modal_supported = media_modal_supported?(url: reference_url, content_type: content_type)

        {
          available: reference_url.present?,
          modal_supported: modal_supported,
          reference_url: reference_url,
          view_url: reference_url,
          download_url: download_url,
          content_type: content_type,
          preview_url: StoryArchive::MediaPreviewResolver.preferred_preview_image_url(event: event, metadata: metadata),
          video_static_frame_only: StoryArchive::MediaPreviewResolver.static_video_preview?(metadata: metadata)
        }
      rescue StandardError
        {
          available: false,
          modal_supported: false,
          reference_url: nil,
          view_url: nil,
          download_url: nil,
          content_type: nil,
          preview_url: nil,
          video_static_frame_only: false
        }
      end

      def infer_content_type(url:, metadata:)
        explicit = metadata["media_content_type"].to_s.presence
        return explicit if explicit

        value = url.to_s.downcase
        return "video/mp4" if value.end_with?(".mp4") || value.end_with?(".mov") || value.end_with?(".webm")
        return "image/jpeg" if value.end_with?(".jpg") || value.end_with?(".jpeg") || value.end_with?(".png") || value.end_with?(".webp")

        nil
      end

      def media_modal_supported?(url:, content_type:)
        return false if url.to_s.blank?
        return true if content_type.to_s.start_with?("image/", "video/")

        path = url.to_s.split("?").first.to_s.downcase
        path.end_with?(".jpg", ".jpeg", ".png", ".webp", ".mp4", ".mov", ".webm")
      end

      def first_present(*values)
        values.find { |value| value.to_s.present? }.to_s.presence
      end
    end
  end
end
