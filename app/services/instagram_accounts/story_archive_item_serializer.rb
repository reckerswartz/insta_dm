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
      ranked_candidates = normalized_ranked_candidates(raw_candidates: llm_meta["ranked_candidates"])
      top_breakdown = llm_meta["selected_relevance_breakdown"].is_a?(Hash) ? llm_meta["selected_relevance_breakdown"] : {}
      generation_policy = generation_policy_for(metadata: metadata, llm_meta: llm_meta)
      generation_inputs = generation_inputs_for(llm_meta: llm_meta)
      policy_diagnostics = policy_diagnostics_for(llm_meta: llm_meta)
      last_failure = last_failure_payload(llm_meta)
      llm_schedule = llm_schedule_payload(llm_meta: llm_meta)
      pipeline = parallel_pipeline(llm_meta)
      pipeline_required_steps = pipeline_required_step_keys(llm_meta)
      pipeline_deferred_steps = LlmComment::ParallelPipelineState::STEP_KEYS - pipeline_required_steps
      analysis_queue = story_analysis_queue_payload(metadata: metadata)
      blob = event.media.blob
      profile = event.instagram_profile
      story_posted_at = metadata["upload_time"].presence || metadata["taken_at"].presence
      downloaded_at = metadata["downloaded_at"].presence || event.occurred_at&.iso8601
      manual_send_status = manual_send_status(metadata)
      normalized_generated_comment = normalize_comment_text(event.llm_generated_comment)

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
        llm_generated_comment: normalized_generated_comment,
        llm_comment_generated_at: event.llm_comment_generated_at&.iso8601,
        llm_comment_model: event.llm_comment_model,
        llm_comment_provider: event.llm_comment_provider,
        llm_model_label: llm_model_label(llm_meta: llm_meta),
        llm_comment_status: event.llm_comment_status,
        llm_pipeline_run_id: pipeline["run_id"].to_s.presence,
        llm_pipeline_status: pipeline["status"].to_s.presence,
        llm_pipeline_provider: pipeline["provider"].to_s.presence || event.llm_comment_provider.to_s.presence,
        llm_pipeline_model: pipeline["model"].to_s.presence || event.llm_comment_model.to_s.presence,
        llm_pipeline_resume_mode: pipeline["resume_mode"].to_s.presence,
        llm_pipeline_required_steps: pipeline_required_steps,
        llm_pipeline_deferred_steps: pipeline_deferred_steps,
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
        llm_ranked_suggestions: ranked_candidates.map { |row| hash_value(row, :comment).to_s.presence }.compact,
        llm_ranked_candidates: ranked_candidates,
        llm_auto_post_allowed: ActiveModel::Type::Boolean.new.cast(llm_meta["auto_post_allowed"]),
        llm_manual_review_reason: llm_manual_review_reason(llm_meta: llm_meta, generation_policy: generation_policy),
        llm_generation_policy: generation_policy,
        llm_policy_allow_comment: llm_policy_allow_comment(generation_policy),
        llm_policy_reason_code: hash_value(generation_policy, :reason_code).to_s.presence,
        llm_policy_reason: hash_value(generation_policy, :reason).to_s.presence,
        llm_policy_source: hash_value(generation_policy, :source).to_s.presence,
        llm_generation_inputs: generation_inputs,
        llm_input_topics: array_from_hash(generation_inputs, :selected_topics, limit: 12),
        llm_input_media_topics: array_from_hash(generation_inputs, :media_topics, limit: 12),
        llm_input_profile_topics: array_from_hash(generation_inputs, :profile_topics, limit: 8),
        llm_input_visual_anchors: array_from_hash(generation_inputs, :visual_anchors, limit: 12),
        llm_input_keywords: array_from_hash(generation_inputs, :context_keywords, limit: 18),
        llm_input_content_mode: hash_value(generation_inputs, :content_mode).to_s.presence,
        llm_input_signal_score: hash_value(generation_inputs, :signal_score).to_i,
        llm_policy_diagnostics: policy_diagnostics,
        llm_rejected_reason_counts: hash_value(policy_diagnostics, :rejected_reason_counts).is_a?(Hash) ? hash_value(policy_diagnostics, :rejected_reason_counts) : {},
        llm_rejected_samples: hash_array_from_hash(policy_diagnostics, :rejected_samples, limit: 5),
        llm_processing_stages: llm_meta["processing_stages"].is_a?(Hash) ? llm_meta["processing_stages"] : {},
        llm_processing_log: Array(llm_meta["processing_log"]).last(24),
        llm_pipeline_step_rollup: pipeline_step_rollup(llm_meta),
        llm_pipeline_timing: pipeline_timing(llm_meta),
        llm_queue_name: llm_schedule[:queue_name],
        llm_queue_state: llm_schedule[:queue_state],
        llm_blocking_step: llm_schedule[:blocking_step],
        llm_pending_reason_code: llm_schedule[:reason_code],
        llm_pending_reason: llm_schedule[:reason],
        llm_schedule_service: llm_schedule[:service],
        llm_schedule_run_at: llm_schedule[:run_at],
        llm_schedule_intentional: llm_schedule[:intentional],
        analysis_status: analysis_queue[:status],
        analysis_status_reason: analysis_queue[:status_reason],
        analysis_failure_reason: analysis_queue[:failure_reason],
        analysis_error_message: analysis_queue[:error_message],
        analysis_updated_at: analysis_queue[:status_updated_at],
        analysis_queue_name: analysis_queue[:queue_name],
        analysis_active_job_id: analysis_queue[:active_job_id],
        analysis_waiting_for_media_attachment: analysis_queue[:waiting_for_media_attachment],
        analysis_media_wait_attempt: analysis_queue[:media_wait_attempt],
        analysis_media_wait_max_attempts: analysis_queue[:media_wait_max_attempts],
        analysis_next_retry_at: analysis_queue[:next_retry_at],
        llm_generated_comment_preview: text_preview(normalized_generated_comment, max: 260),
        has_llm_comment: normalized_generated_comment.present?,
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
      hash_value(last_failure, :reason).to_s.presence || (
        generation_policy_blocks_comment?(generation_policy) ? hash_value(generation_policy, :reason_code).to_s.presence : nil
      )
    end

    def llm_failure_source(last_failure:, generation_policy:)
      hash_value(last_failure, :source).to_s.presence || (
        generation_policy_blocks_comment?(generation_policy) ? hash_value(generation_policy, :source).to_s.presence : nil
      )
    end

    def llm_failure_message(last_failure:, generation_policy:)
      event.llm_comment_last_error.to_s.presence ||
        hash_value(last_failure, :error_message).to_s.presence ||
        (generation_policy_blocks_comment?(generation_policy) ? hash_value(generation_policy, :reason).to_s.presence : nil)
    end

    def llm_policy_allow_comment(generation_policy)
      return nil unless generation_policy.is_a?(Hash)
      return nil unless generation_policy.key?("allow_comment") || generation_policy.key?(:allow_comment)

      ActiveModel::Type::Boolean.new.cast(hash_value(generation_policy, :allow_comment))
    end

    def llm_manual_review_reason(llm_meta:, generation_policy:)
      explicit_reason = hash_value(llm_meta, :manual_review_reason).to_s.presence
      return explicit_reason if explicit_reason.present?
      return nil unless ActiveModel::Type::Boolean.new.cast(hash_value(generation_policy, :manual_review_required))

      hash_value(generation_policy, :manual_review_reason).to_s.presence ||
        hash_value(generation_policy, :reason).to_s.presence
    rescue StandardError
      nil
    end

    def generation_inputs_for(llm_meta:)
      data = hash_value(llm_meta, :generation_inputs)
      data.is_a?(Hash) ? data : {}
    rescue StandardError
      {}
    end

    def policy_diagnostics_for(llm_meta:)
      data = hash_value(llm_meta, :policy_diagnostics)
      data.is_a?(Hash) ? data : {}
    rescue StandardError
      {}
    end

    def array_from_hash(row, key, limit:)
      value = hash_value(row, key)
      Array(value).map(&:to_s).map(&:strip).reject(&:blank?).uniq.first(limit.to_i.clamp(1, 64))
    rescue StandardError
      []
    end

    def hash_array_from_hash(row, key, limit:)
      value = hash_value(row, key)
      Array(value).select { |entry| entry.is_a?(Hash) }.first(limit.to_i.clamp(1, 64))
    rescue StandardError
      []
    end

    def generation_policy_blocks_comment?(generation_policy)
      return false unless generation_policy.is_a?(Hash)
      return false unless generation_policy.key?("allow_comment") || generation_policy.key?(:allow_comment)

      !ActiveModel::Type::Boolean.new.cast(hash_value(generation_policy, :allow_comment))
    end

    def llm_model_label(llm_meta:)
      pipeline = parallel_pipeline(llm_meta)
      event_status = event.llm_comment_status.to_s
      pipeline_status = pipeline["status"].to_s
      pipeline_label = model_label_for(provider: pipeline["provider"], model: pipeline["model"])

      if event_status.in?(%w[queued running]) || pipeline_status == "running"
        return pipeline_label if pipeline_label.present?
      end

      event_label = model_label_for(provider: event.llm_comment_provider, model: event.llm_comment_model)
      return event_label if event_label.present?
      return pipeline_label if pipeline_label.present?

      "-"
    end

    def model_label_for(provider:, model:)
      provider_name = provider.to_s.strip
      model_name = model.to_s.strip
      return nil if provider_name.blank? && model_name.blank?
      return provider_name if provider_name.present? && model_name.blank?
      return model_name if model_name.present? && provider_name.blank?

      "#{provider_name} / #{model_name}"
    end

    def llm_schedule_payload(llm_meta:)
      blocking_step = event.llm_blocking_step.to_s.presence || inferred_blocking_step(llm_meta)
      reason_code = event.llm_pending_reason_code.to_s.presence || inferred_schedule_reason_code(llm_meta)
      run_at = event.llm_estimated_ready_at&.iso8601
      status = event.llm_comment_status.to_s
      include_queue = status.in?(%w[queued running]) || reason_code.to_s.present? || run_at.to_s.present?

      {
        queue_name: include_queue ? queue_name_for_schedule(blocking_step: blocking_step) : nil,
        queue_state: include_queue ? queue_state_for_schedule(reason_code: reason_code) : nil,
        blocking_step: blocking_step,
        reason_code: reason_code,
        reason: schedule_reason_for(reason_code: reason_code, blocking_step: blocking_step),
        service: include_queue ? schedule_service_for(reason_code: reason_code, blocking_step: blocking_step) : nil,
        run_at: run_at,
        intentional: reason_code.to_s.present? ? (reason_code != "unknown_scheduled_delay") : nil
      }.compact
    rescue StandardError
      {}
    end

    def inferred_schedule_reason_code(llm_meta)
      resource_guard = llm_meta["resource_guard_defer"].is_a?(Hash)
      timeout_resume = llm_meta["timeout_resume"].is_a?(Hash)
      return "resource_guard_delay" if resource_guard
      return "timeout_resume_delay" if timeout_resume

      status = event.llm_comment_status.to_s
      return "queued_llm_generation" if status == "queued" && event.llm_estimated_ready_at.present?
      return "running_llm_generation" if status == "running"

      nil
    rescue StandardError
      nil
    end

    def inferred_blocking_step(llm_meta)
      pipeline = parallel_pipeline(llm_meta)
      steps = pipeline["steps"].is_a?(Hash) ? pipeline["steps"] : {}
      required = pipeline_required_step_keys(llm_meta)
      required.find do |step|
        status = steps.dig(step.to_s, "status").to_s
        !status.in?(%w[succeeded failed skipped])
      end
    rescue StandardError
      nil
    end

    def queue_name_for_schedule(blocking_step:)
      service_key =
        if blocking_step.to_s.present?
          LlmComment::ParallelPipelineState::STEP_TO_QUEUE_SERVICE_KEY[blocking_step.to_s]
        else
          :llm_comment_generation
        end
      queue_name = Ops::AiServiceQueueRegistry.queue_name_for(service_key)
      queue_name.to_s.presence || Ops::AiServiceQueueRegistry.queue_name_for(:llm_comment_generation).to_s
    rescue StandardError
      Ops::AiServiceQueueRegistry.queue_name_for(:llm_comment_generation).to_s
    end

    def queue_state_for_schedule(reason_code:)
      status = event.llm_comment_status.to_s
      reason = reason_code.to_s
      return "processing" if status == "running"
      return "ready" if status == "completed"
      return "failed" if status == "failed"
      return "skipped" if status == "skipped"
      return "scheduled" if event.llm_estimated_ready_at.present?
      return "scheduled" if reason.start_with?("queued_", "waiting_", "failed_", "pipeline_finalizing")
      return "queued" if status == "queued"

      status.presence || "ready"
    rescue StandardError
      "ready"
    end

    def schedule_reason_for(reason_code:, blocking_step:)
      code = reason_code.to_s
      return nil if code.blank?

      return "LLM generation is currently processing." if code == "running_llm_generation"
      return "LLM generation is queued behind earlier jobs." if code == "queued_llm_generation"
      return "Pipeline finalizer is waiting for required steps to complete." if code == "pipeline_finalizing"
      return "Deferred by local AI resource guard to protect hardware limits." if code == "resource_guard_delay"
      return "Rescheduled after timeout guardrail to continue safely." if code == "timeout_resume_delay"

      if code.start_with?("queued_")
        step_key = code.delete_prefix("queued_")
        return "Queued behind #{humanize_step_key(step_key)} jobs."
      end
      if code.start_with?("running_")
        step_key = code.delete_prefix("running_")
        return "#{humanize_step_key(step_key)} is currently processing."
      end
      if code.start_with?("waiting_")
        step_key = code.delete_prefix("waiting_")
        return "Waiting for dependency #{humanize_step_key(step_key)}."
      end
      if code.start_with?("failed_")
        step_key = code.delete_prefix("failed_")
        return "#{humanize_step_key(step_key)} failed and is waiting for retry."
      end

      if blocking_step.to_s.present?
        "Waiting for #{humanize_step_key(blocking_step)}."
      else
        "Queued with scheduling reason #{code.tr('_', ' ')}."
      end
    rescue StandardError
      nil
    end

    def schedule_service_for(reason_code:, blocking_step:)
      code = reason_code.to_s
      return "GenerateLlmCommentJob" if code.in?(%w[resource_guard_delay timeout_resume_delay queued_llm_generation running_llm_generation])
      return "FinalizeStoryCommentPipelineJob" if code == "pipeline_finalizing"

      if blocking_step.to_s.present?
        step = LlmComment::StepRegistry.step_for(blocking_step.to_s)
        return step.job_class_name.to_s if step&.job_class_name.to_s.present?
      end

      "GenerateLlmCommentJob"
    rescue StandardError
      "GenerateLlmCommentJob"
    end

    def humanize_step_key(value)
      key = value.to_s
      return "pipeline stage" if key.blank?

      key
        .tr("_", " ")
        .split
        .map(&:capitalize)
        .join(" ")
    rescue StandardError
      "pipeline stage"
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

    def normalized_ranked_candidates(raw_candidates:)
      Array(raw_candidates).filter_map do |row|
        next unless row.is_a?(Hash)

        comment = normalize_comment_text(hash_value(row, :comment))
        next if comment.blank?

        row.deep_dup.merge("comment" => comment)
      end.first(8)
    rescue StandardError
      []
    end

    def normalize_comment_text(raw)
      text = raw.to_s.strip
      return "" if text.blank?

      quote_pairs = [
        ['"', '"'],
        ["'", "'"],
        ["“", "”"],
        ["‘", "’"]
      ]
      quote_pairs.each do |opening, closing|
        next unless text.length > (opening.length + closing.length)
        next unless text.start_with?(opening) && text.end_with?(closing)

        text = text[opening.length...-closing.length].to_s.strip
      end

      text.gsub(/\A["'“”‘’]+|["'“”‘’]+\z/, "").strip
    rescue StandardError
      raw.to_s.strip
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
      return "skipped" if llm_status == "skipped"
      return "queued" if llm_status == "queued" || manual == "queued"
      return "processing" if llm_status.in?(%w[running]) || manual.in?(%w[sending running])
      return "partial" if llm_status == "completed" && failed_pipeline
      return "ready" if llm_status.in?(%w[completed not_requested])
      return "ready" if llm_status.blank?

      "ready"
    rescue StandardError
      "ready"
    end

    def story_analysis_queue_payload(metadata:)
      story_id = metadata["story_id"].to_s.presence
      return {} if story_id.blank?

      queue_metadata = story_analysis_queue_metadata(story_id: story_id)
      payload = queue_metadata.is_a?(Hash) ? queue_metadata.deep_dup : {}

      status = payload["status"].to_s.presence
      if status.blank? || status.in?(%w[queued started running processing])
        if analyzed_story_event_exists?(story_id: story_id)
          payload["status"] = "completed"
          payload["status_reason"] ||= "analysis_event_recorded"
          payload["status_updated_at"] ||= Time.current.iso8601(3)
        end
      end

      payload.slice(
        "status",
        "status_reason",
        "failure_reason",
        "error_message",
        "status_updated_at",
        "queue_name",
        "active_job_id",
        "waiting_for_media_attachment",
        "media_wait_attempt",
        "media_wait_max_attempts",
        "next_retry_at"
      ).transform_keys(&:to_sym)
    rescue StandardError
      {}
    end

    def story_analysis_queue_metadata(story_id:)
      queue_event = event.instagram_profile.instagram_profile_events.find_by(
        kind: "story_analysis_queued",
        external_id: "story_analysis_queued:#{story_id}"
      )
      queue_event&.metadata.is_a?(Hash) ? queue_event.metadata : {}
    rescue StandardError
      {}
    end

    def analyzed_story_event_exists?(story_id:)
      event.instagram_profile.instagram_profile_events
        .where(kind: "story_analyzed")
        .where("metadata ->> 'story_id' = ?", story_id.to_s)
        .exists?
    rescue StandardError
      false
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
      media_done = pipeline_required_step_keys(llm_meta).all? do |key|
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
      pipeline_required_step_keys(llm_meta).any? do |key|
        row = rollup[key]
        row.is_a?(Hash) && row[:status].to_s == "failed"
      end
    rescue StandardError
      false
    end

    def pipeline_required_step_keys(llm_meta)
      pipeline = parallel_pipeline(llm_meta)
      configured = Array(pipeline["required_steps"]).map(&:to_s).select do |key|
        LlmComment::ParallelPipelineState::STEP_KEYS.include?(key)
      end
      return configured if configured.present?

      LlmComment::ParallelPipelineState::REQUIRED_STEP_KEYS
    rescue StandardError
      LlmComment::ParallelPipelineState::REQUIRED_STEP_KEYS
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
