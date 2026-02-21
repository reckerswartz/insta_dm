module InstagramAccounts
  class StoryArchiveItemSerializer
    DEFAULT_PREVIEW_ENQUEUE_TTL_SECONDS = Integer(ENV.fetch("STORY_ARCHIVE_PREVIEW_ENQUEUE_TTL_SECONDS", "900"))

    def initialize(event:, preview_enqueue_ttl_seconds: DEFAULT_PREVIEW_ENQUEUE_TTL_SECONDS)
      @event = event
      @preview_enqueue_ttl_seconds = preview_enqueue_ttl_seconds.to_i
    end

    def call
      metadata = event.metadata.is_a?(Hash) ? event.metadata : {}
      llm_meta = event.llm_comment_metadata.is_a?(Hash) ? event.llm_comment_metadata : {}
      ownership_data = extract_ownership_data(metadata: metadata, llm_meta: llm_meta)
      ranked_candidates = Array(llm_meta["ranked_candidates"]).select { |row| row.is_a?(Hash) }.first(8)
      top_breakdown = llm_meta["selected_relevance_breakdown"].is_a?(Hash) ? llm_meta["selected_relevance_breakdown"] : {}
      generation_policy = if llm_meta["generation_policy"].is_a?(Hash)
        llm_meta["generation_policy"]
      elsif metadata.dig("validated_story_insights", "generation_policy").is_a?(Hash)
        metadata.dig("validated_story_insights", "generation_policy")
      else
        {}
      end
      blob = event.media.blob
      profile = event.instagram_profile
      story_posted_at = metadata["upload_time"].presence || metadata["taken_at"].presence
      downloaded_at = metadata["downloaded_at"].presence || event.occurred_at&.iso8601
      manual_send_status = manual_send_status(metadata)

      {
        id: event.id,
        profile_id: event.instagram_profile_id,
        profile_username: profile&.username.to_s,
        profile_display_name: profile&.display_name.to_s.presence || profile&.username.to_s,
        profile_avatar_url: profile_avatar_url(profile),
        app_profile_url: event.instagram_profile_id ? Rails.application.routes.url_helpers.instagram_profile_path(event.instagram_profile_id) : nil,
        instagram_profile_url: profile&.username.present? ? "https://www.instagram.com/#{profile.username}/" : nil,
        story_posted_at: story_posted_at,
        downloaded_at: downloaded_at,
        media_url: blob_path(event.media),
        media_download_url: blob_path(event.media, disposition: "attachment"),
        media_content_type: blob&.content_type.to_s.presence || metadata["media_content_type"].to_s,
        media_preview_image_url: media_preview_image_url(metadata: metadata),
        video_static_frame_only: StoryArchive::MediaPreviewResolver.static_video_preview?(metadata: metadata),
        media_bytes: metadata["media_bytes"].to_i.positive? ? metadata["media_bytes"].to_i : blob&.byte_size.to_i,
        media_width: metadata["media_width"],
        media_height: metadata["media_height"],
        story_id: metadata["story_id"].to_s,
        story_url: metadata["story_url"].to_s.presence || metadata["permalink"].to_s.presence,
        reply_comment: metadata["reply_comment"].to_s.presence,
        manual_send_status: manual_send_status,
        manual_send_message: metadata["manual_send_message"].to_s.presence,
        manual_send_reason: metadata["manual_send_reason"].to_s.presence,
        manual_send_last_error: metadata["manual_send_last_error"].to_s.presence,
        manual_send_last_comment: metadata["manual_send_last_comment"].to_s.presence,
        manual_send_attempt_count: metadata["manual_send_attempt_count"].to_i,
        manual_send_last_attempted_at: metadata["manual_send_last_attempted_at"].to_s.presence,
        manual_send_last_sent_at: metadata["manual_send_last_sent_at"].to_s.presence || metadata["manual_resend_last_at"].to_s.presence,
        manual_send_updated_at: metadata["manual_send_updated_at"].to_s.presence,
        skipped: ActiveModel::Type::Boolean.new.cast(metadata["skipped"]),
        skip_reason: metadata["skip_reason"].to_s.presence,
        llm_generated_comment: event.llm_generated_comment,
        llm_comment_generated_at: event.llm_comment_generated_at&.iso8601,
        llm_comment_model: event.llm_comment_model,
        llm_comment_provider: event.llm_comment_provider,
        llm_comment_status: event.llm_comment_status,
        llm_comment_attempts: event.llm_comment_attempts,
        llm_comment_last_error: event.llm_comment_last_error,
        llm_comment_last_error_preview: text_preview(event.llm_comment_last_error, max: 180),
        llm_comment_relevance_score: event.llm_comment_relevance_score,
        llm_relevance_breakdown: top_breakdown,
        llm_ranked_suggestions: ranked_candidates.map { |row| row["comment"].to_s.presence }.compact,
        llm_ranked_candidates: ranked_candidates,
        llm_auto_post_allowed: ActiveModel::Type::Boolean.new.cast(llm_meta["auto_post_allowed"]),
        llm_manual_review_reason: llm_meta["manual_review_reason"].to_s.presence || generation_policy["reason"].to_s.presence,
        llm_generation_policy: generation_policy,
        llm_processing_stages: llm_meta["processing_stages"].is_a?(Hash) ? llm_meta["processing_stages"] : {},
        llm_processing_log: Array(llm_meta["processing_log"]).last(24),
        llm_generated_comment_preview: text_preview(event.llm_generated_comment, max: 260),
        has_llm_comment: event.has_llm_generated_comment?,
        story_ownership_label: ownership_data["label"].to_s.presence,
        story_ownership_summary: ownership_data["summary"].to_s.presence,
        story_ownership_confidence: ownership_data["confidence"]
      }
    end

    private

    attr_reader :event, :preview_enqueue_ttl_seconds

    def extract_ownership_data(metadata:, llm_meta:)
      if llm_meta["ownership_classification"].is_a?(Hash)
        llm_meta["ownership_classification"]
      elsif metadata["story_ownership_classification"].is_a?(Hash)
        metadata["story_ownership_classification"]
      elsif metadata.dig("validated_story_insights", "ownership_classification").is_a?(Hash)
        metadata.dig("validated_story_insights", "ownership_classification")
      else
        {}
      end
    end

    def blob_path(attachment, disposition: nil)
      options = { only_path: true }
      options[:disposition] = disposition if disposition.present?
      Rails.application.routes.url_helpers.rails_blob_path(attachment, **options)
    rescue StandardError
      nil
    end

    def profile_avatar_url(profile)
      return nil unless profile

      if profile.avatar.attached?
        blob_path(profile.avatar)
      else
        profile.profile_pic_url.to_s.presence
      end
    end

    def media_preview_image_url(metadata:)
      url = StoryArchive::MediaPreviewResolver.preferred_preview_image_url(event: event, metadata: metadata)
      return url if url.present?

      local_video_preview_representation_url
    end

    def local_video_preview_representation_url
      return nil unless event.media.attached?
      return nil unless event.media.blob&.content_type.to_s.start_with?("video/")

      enqueue_story_preview_generation
      nil
    rescue StandardError
      nil
    end

    def enqueue_story_preview_generation
      return if event.preview_image.attached?
      return if preview_generation_permanently_failed?

      cache_key = "story_archive:preview_enqueue:#{event.id}"
      Rails.cache.fetch(cache_key, expires_in: preview_enqueue_ttl_seconds.seconds) do
        GenerateStoryPreviewImageJob.perform_later(instagram_profile_event_id: event.id)
        true
      end
    rescue StandardError => e
      Rails.logger.warn("[story_media_archive] preview enqueue failed event_id=#{event.id}: #{e.class}: #{e.message}")
    end

    def preview_generation_permanently_failed?
      metadata = event.metadata.is_a?(Hash) ? event.metadata : {}
      metadata["preview_image_status"].to_s == "failed" &&
        metadata["preview_image_failure_reason"].to_s == "invalid_video_stream"
    end

    def text_preview(raw, max:)
      text = raw.to_s
      return text if text.length <= max

      "#{text[0, max]}..."
    end

    def manual_send_status(metadata)
      status = metadata["manual_send_status"].to_s.strip
      return status if status.present?

      return "sent" if metadata["manual_resend_last_at"].to_s.present?
      return "sent" if metadata["reply_comment"].to_s.present?

      "ready"
    end
  end
end
