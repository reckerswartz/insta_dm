module InstagramProfiles
  class TabulatorEventsPayloadBuilder
    def initialize(events:, total:, pages:, view_context:)
      @events = events
      @total = total
      @pages = pages
      @view_context = view_context
    end

    def call
      {
        data: events.map { |event| serialize_event(event) },
        last_page: pages,
        last_row: total
      }
    end

    private

    attr_reader :events, :total, :pages, :view_context

    def serialize_event(event)
      metadata = event.metadata.is_a?(Hash) ? event.metadata : {}
      media_attached = event.media.attached?

      {
        id: event.id,
        kind: event.kind,
        external_id: event.external_id,
        occurred_at: event.occurred_at&.iso8601,
        detected_at: event.detected_at&.iso8601,
        metadata_json: metadata_preview_json(metadata),
        media_content_type: media_attached ? event.media.blob.content_type : nil,
        media_url: media_attached ? blob_path(event.media) : nil,
        media_download_url: media_attached ? blob_path(event.media, disposition: "attachment") : nil,
        media_preview_image_url: media_preview_image_url(event: event, metadata: metadata),
        video_static_frame_only: StoryArchive::MediaPreviewResolver.static_video_preview?(metadata: metadata)
      }
    end

    def media_preview_image_url(event:, metadata:)
      url = StoryArchive::MediaPreviewResolver.preferred_preview_image_url(event: event, metadata: metadata)
      return url if url.present?

      local_video_preview_representation_url(event: event)
    end

    def local_video_preview_representation_url(event:)
      return nil unless event.media.attached?
      return nil unless event.media.blob&.content_type.to_s.start_with?("video/")

      preview = event.media.preview(resize_to_limit: [640, 640]).processed
      view_context.url_for(preview)
    rescue StandardError
      nil
    end

    def metadata_preview_json(raw_metadata)
      json = (raw_metadata || {}).to_json
      return json if json.length <= 1200

      "#{json[0, 1200]}..."
    end

    def blob_path(attachment, disposition: nil)
      options = { only_path: true }
      options[:disposition] = disposition if disposition.present?
      Rails.application.routes.url_helpers.rails_blob_path(attachment, **options)
    end
  end
end
