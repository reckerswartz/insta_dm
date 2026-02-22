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
      generation_policy = generation_policy_for(metadata: metadata, llm_meta: llm_meta)
      last_failure = last_failure_payload(llm_meta)
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
        manual_send_quality_review: metadata["manual_send_quality_review"].is_a?(Hash) ? metadata["manual_send_quality_review"] : {},
        skipped: ActiveModel::Type::Boolean.new.cast(metadata["skipped"]),
        skip_reason: metadata["skip_reason"].to_s.presence,
        llm_generated_comment: event.llm_generated_comment,
        llm_comment_generated_at: event.llm_comment_generated_at&.iso8601,
        llm_comment_model: event.llm_comment_model,
        llm_comment_provider: event.llm_comment_provider,
        llm_model_label: llm_model_label,
        llm_comment_status: event.llm_comment_status,
        llm_workflow_status: llm_workflow_status(event: event, llm_meta: llm_meta, manual_send_status: manual_send_status),
        llm_workflow_progress: llm_workflow_progress(event: event, llm_meta: llm_meta, manual_send_status: manual_send_status),
        llm_comment_attempts: event.llm_comment_attempts,
        llm_comment_last_error: event.llm_comment_last_error,
        llm_comment_last_error_preview: text_preview(event.llm_comment_last_error, max: 180),
        llm_failure_reason_code: llm_failure_reason_code(last_failure: last_failure, generation_policy: generation_policy),
        llm_failure_source: llm_failure_source(last_failure: last_failure, generation_policy: generation_policy),
        llm_failure_error_class: hash_value(last_failure, :error_class).to_s.presence,
        llm_failure_message: llm_failure_message(last_failure: last_failure, generation_policy: generation_policy),
        llm_comment_relevance_score: event.llm_comment_relevance_score,
        llm_relevance_breakdown: top_breakdown,
        llm_ranked_suggestions: ranked_candidates.map { |row| row["comment"].to_s.presence }.compact,
        llm_ranked_candidates: ranked_candidates,
        llm_auto_post_allowed: ActiveModel::Type::Boolean.new.cast(llm_meta["auto_post_allowed"]),
        llm_manual_review_reason: llm_meta["manual_review_reason"].to_s.presence || generation_policy["reason"].to_s.presence,
        llm_generation_policy: generation_policy,
        llm_policy_allow_comment: llm_policy_allow_comment(generation_policy),
        llm_policy_reason_code: hash_value(generation_policy, :reason_code).to_s.presence,
        llm_policy_reason: hash_value(generation_policy, :reason).to_s.presence,
        llm_policy_source: hash_value(generation_policy, :source).to_s.presence,
        llm_processing_stages: llm_meta["processing_stages"].is_a?(Hash) ? llm_meta["processing_stages"] : {},
        llm_processing_log: Array(llm_meta["processing_log"]).last(24),
        llm_pipeline_step_rollup: pipeline_step_rollup(llm_meta),
        llm_pipeline_timing: pipeline_timing(llm_meta),
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

    def generation_policy_for(metadata:, llm_meta:)
      if hash_value(llm_meta, :generation_policy).is_a?(Hash)
        hash_value(llm_meta, :generation_policy)
      elsif metadata.dig("validated_story_insights", "generation_policy").is_a?(Hash)
        metadata.dig("validated_story_insights", "generation_policy")
      elsif metadata["story_generation_policy"].is_a?(Hash)
        metadata["story_generation_policy"]
      else
        {}
      end
    end

    def last_failure_payload(llm_meta)
      row = hash_value(llm_meta, :last_failure)
      row.is_a?(Hash) ? row : {}
    end

    def llm_failure_reason_code(last_failure:, generation_policy:)
      hash_value(last_failure, :reason).to_s.presence || hash_value(generation_policy, :reason_code).to_s.presence
    end

    def llm_failure_source(last_failure:, generation_policy:)
      hash_value(last_failure, :source).to_s.presence || hash_value(generation_policy, :source).to_s.presence
    end

    def llm_failure_message(last_failure:, generation_policy:)
      event.llm_comment_last_error.to_s.presence ||
        hash_value(last_failure, :error_message).to_s.presence ||
        hash_value(generation_policy, :reason).to_s.presence
    end

    def llm_policy_allow_comment(generation_policy)
      return nil unless generation_policy.is_a?(Hash)
      return nil unless generation_policy.key?("allow_comment") || generation_policy.key?(:allow_comment)

      ActiveModel::Type::Boolean.new.cast(hash_value(generation_policy, :allow_comment))
    end

    def llm_model_label
      provider = event.llm_comment_provider.to_s.strip
      model = event.llm_comment_model.to_s.strip
      return "-" if provider.blank? && model.blank?
      return provider if provider.present? && model.blank?
      return model if model.present? && provider.blank?

      "#{provider} / #{model}"
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

    def hash_value(row, key)
      return nil unless row.is_a?(Hash)
      return row[key.to_s] if row.key?(key.to_s)
      return row[key.to_sym] if row.key?(key.to_sym)

      nil
    rescue StandardError
      nil
    end

    def llm_workflow_status(event:, llm_meta:, manual_send_status:)
      llm_status = event.llm_comment_status.to_s
      manual = manual_send_status.to_s
      failed_pipeline = pipeline_has_failed_steps?(llm_meta)

      return "failed" if llm_status.in?(%w[failed]) || manual.in?(%w[failed expired_removed])
      return "queued" if llm_status == "queued" || manual == "queued"
      return "processing" if llm_status.in?(%w[running]) || manual.in?(%w[sending running])
      return "partial" if llm_status == "completed" && failed_pipeline
      return "ready" if llm_status == "completed"

      "queued"
    rescue StandardError
      "queued"
    end

    def llm_workflow_progress(event:, llm_meta:, manual_send_status:)
      llm_status = event.llm_comment_status.to_s
      manual = manual_send_status.to_s
      steps = completed_workflow_steps(event: event, llm_meta: llm_meta, manual_send_status: manual)
      total = 5
      {
        completed: steps,
        total: total,
        summary: "#{steps}/#{total} completed"
      }
    rescue StandardError
      { completed: 0, total: 5, summary: "0/5 completed" }
    end

    def completed_workflow_steps(event:, llm_meta:, manual_send_status:)
      completed = 0
      rollup = pipeline_step_rollup(llm_meta)
      media_done = LlmComment::ParallelPipelineState::STEP_KEYS.all? do |key|
        state = rollup.dig(key, :status).to_s
        state.in?(%w[succeeded skipped])
      end
      completed += 1 if media_done

      stages = event.llm_processing_stages
      completed += 1 if stages.dig("context_matching", "state").to_s.in?(%w[completed completed_with_warnings])
      completed += 1 if event.llm_comment_status.to_s == "completed"
      completed += 1 if stages.dig("engagement_eligibility", "state").to_s.in?(%w[completed])
      completed += 1 if manual_send_status.to_s == "sent"
      completed
    end

    def pipeline_has_failed_steps?(llm_meta)
      rollup = pipeline_step_rollup(llm_meta)
      rollup.values.any? do |row|
        row.is_a?(Hash) && row[:status].to_s == "failed"
      end
    rescue StandardError
      false
    end

    def parallel_pipeline(llm_meta)
      row = llm_meta["parallel_pipeline"]
      row.is_a?(Hash) ? row : {}
    rescue StandardError
      {}
    end

    def pipeline_step_rollup(llm_meta)
      pipeline = parallel_pipeline(llm_meta)
      steps = pipeline["steps"]
      return {} unless steps.is_a?(Hash)

      LlmComment::ParallelPipelineState::STEP_KEYS.each_with_object({}) do |step, out|
        row = steps[step].is_a?(Hash) ? steps[step] : {}
        out[step] = {
          status: row["status"].to_s.presence || "pending",
          queue_name: row["queue_name"].to_s.presence,
          queued_at: row["queued_at"].to_s.presence || row["created_at"].to_s.presence,
          started_at: row["started_at"].to_s.presence,
          finished_at: row["finished_at"].to_s.presence,
          queue_wait_ms: row["queue_wait_ms"],
          run_duration_ms: row["run_duration_ms"],
          total_duration_ms: row["total_duration_ms"],
          attempts: row["attempts"].to_i,
          error: row["error"].to_s.presence
        }.compact
      end
    rescue StandardError
      {}
    end

    def pipeline_timing(llm_meta)
      pipeline = parallel_pipeline(llm_meta)
      return {} unless pipeline.is_a?(Hash)

      generation = pipeline["generation"].is_a?(Hash) ? pipeline["generation"] : {}
      details = pipeline["details"].is_a?(Hash) ? pipeline["details"] : {}
      created_at = parse_time(pipeline["created_at"])
      finished_at = parse_time(pipeline["finished_at"])
      generation_started_at = parse_time(generation["started_at"])
      generation_finished_at = parse_time(generation["finished_at"])

      {
        run_id: pipeline["run_id"].to_s.presence,
        status: pipeline["status"].to_s.presence,
        created_at: pipeline["created_at"].to_s.presence,
        finished_at: pipeline["finished_at"].to_s.presence,
        pipeline_duration_ms: details["pipeline_duration_ms"] || duration_ms(start_time: created_at, end_time: finished_at),
        generation_duration_ms: details["generation_duration_ms"] || duration_ms(start_time: generation_started_at, end_time: generation_finished_at)
      }.compact
    rescue StandardError
      {}
    end

    def parse_time(value)
      return nil if value.to_s.blank?

      Time.zone.parse(value.to_s)
    rescue StandardError
      nil
    end

    def duration_ms(start_time:, end_time:)
      return nil unless start_time && end_time

      ((end_time.to_f - start_time.to_f) * 1000.0).round
    rescue StandardError
      nil
    end
  end
end
