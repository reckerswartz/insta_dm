module InstagramAccounts
  class LlmCommentRequestService
    Result = Struct.new(:payload, :status, keyword_init: true)

    def initialize(account:, event_id:, provider:, model:, status_only:, force: false, queue_inspector: LlmQueueInspector.new)
      @account = account
      @event_id = event_id
      @provider = provider.to_s
      @model = model
      @status_only = ActiveModel::Type::Boolean.new.cast(status_only)
      @force = ActiveModel::Type::Boolean.new.cast(force)
      @queue_inspector = queue_inspector
    end

    def call
      event = InstagramProfileEvent.find(event_id)
      return not_found_result unless accessible_event?(event)

      completed = normalize_completed_event(event)
      return completed if completed && !force

      in_progress = normalize_in_progress_event(event)
      return in_progress if in_progress

      return status_result(event) if status_only

      enqueue_comment_job(event, force: force)
    rescue StandardError => e
      Result.new(payload: { error: e.message }, status: :unprocessable_entity)
    end

    private

    attr_reader :account, :event_id, :provider, :model, :status_only, :force, :queue_inspector

    def accessible_event?(event)
      event.story_archive_item? && event.instagram_profile&.instagram_account_id == account.id
    end

    def not_found_result
      Result.new(payload: { error: "Event not found or not accessible" }, status: :not_found)
    end

    def completed_result(event)
      llm_meta = event.llm_comment_metadata.is_a?(Hash) ? event.llm_comment_metadata : {}
      Result.new(
        payload: {
          success: true,
          status: "completed",
          event_id: event.id,
          llm_generated_comment: event.llm_generated_comment,
          llm_comment_generated_at: event.llm_comment_generated_at,
          llm_comment_model: event.llm_comment_model,
          llm_comment_provider: event.llm_comment_provider,
          llm_comment_relevance_score: event.llm_comment_relevance_score,
          llm_ranked_candidates: Array(llm_meta["ranked_candidates"]).first(8),
          llm_relevance_breakdown: llm_meta["selected_relevance_breakdown"].is_a?(Hash) ? llm_meta["selected_relevance_breakdown"] : {},
          llm_processing_stages: merged_llm_processing_stages(event),
          llm_processing_log: merged_llm_processing_log(event),
          llm_last_stage: merged_llm_last_stage(event),
          llm_manual_review_reason: llm_meta["manual_review_reason"].to_s.presence,
          llm_auto_post_allowed: ActiveModel::Type::Boolean.new.cast(llm_meta["auto_post_allowed"])
        },
        status: :ok
      )
    end

    def normalize_completed_event(event)
      return nil unless event.has_llm_generated_comment?

      event.update_column(:llm_comment_status, "completed") if event.llm_comment_status.to_s != "completed"
      completed_result(event)
    end

    def normalize_in_progress_event(event)
      return nil unless event.llm_comment_in_progress?

      if queue_inspector.stale_comment_job?(event: event)
        event.update_columns(
          llm_comment_status: "failed",
          llm_comment_last_error: "Previous generation job appears stalled. Please retry.",
          updated_at: Time.current
        )
        event.reload
        return nil
      end

      in_progress_result(event)
    end

    def enqueue_comment_job(event, force: false)
      event.with_lock do
        event.reload

        completed = normalize_completed_event(event)
        return completed if completed && !force

        in_progress = normalize_in_progress_event(event)
        return in_progress if in_progress

        reset_generation_state!(event) if force && event.has_llm_generated_comment?

        job = GenerateLlmCommentJob.perform_later(
          instagram_profile_event_id: event.id,
          provider: provider,
          model: model,
          requested_by: "dashboard_manual_request"
        )
        event.queue_llm_comment_generation!(job_id: job.job_id)

        Result.new(
          payload: {
            success: true,
            status: "queued",
            event_id: event.id,
            job_id: job.job_id,
            estimated_seconds: llm_comment_estimated_seconds(event: event, include_queue: true),
            queue_size: ai_queue_size,
            llm_processing_stages: merged_llm_processing_stages(event),
            llm_processing_log: merged_llm_processing_log(event),
            llm_last_stage: merged_llm_last_stage(event),
            forced: force
          },
          status: :accepted
        )
      end
    end

    def reset_generation_state!(event)
      event.update_columns(
        llm_generated_comment: nil,
        llm_comment_generated_at: nil,
        llm_comment_model: nil,
        llm_comment_provider: nil,
        llm_comment_relevance_score: nil,
        llm_comment_last_error: nil,
        llm_comment_status: "not_requested",
        llm_comment_metadata: {},
        updated_at: Time.current
      )
      event.reload
    end

    def in_progress_result(event)
      Result.new(
        payload: {
          success: true,
          status: event.llm_comment_status,
          event_id: event.id,
          job_id: event.llm_comment_job_id,
          estimated_seconds: llm_comment_estimated_seconds(event: event),
          queue_size: ai_queue_size,
          llm_processing_stages: merged_llm_processing_stages(event),
          llm_processing_log: merged_llm_processing_log(event),
          llm_last_stage: merged_llm_last_stage(event)
        },
        status: :accepted
      )
    end

    def status_result(event)
      Result.new(
        payload: {
          success: true,
          status: event.llm_comment_status.presence || "not_requested",
          event_id: event.id,
          estimated_seconds: llm_comment_estimated_seconds(event: event),
          queue_size: ai_queue_size,
          llm_processing_stages: merged_llm_processing_stages(event),
          llm_processing_log: merged_llm_processing_log(event),
          llm_last_stage: merged_llm_last_stage(event)
        },
        status: :ok
      )
    end

    def merged_llm_processing_stages(event)
      merge_stage_hashes(
        local_processing_stages(event),
        llm_processing_stages(event)
      )
    end

    def merged_llm_processing_log(event)
      (local_processing_log(event) + llm_processing_log(event)).last(40)
    end

    def merged_llm_last_stage(event)
      merged_llm_processing_log(event).last
    end

    def llm_processing_stages(event)
      llm_meta = event.llm_comment_metadata.is_a?(Hash) ? event.llm_comment_metadata : {}
      llm_meta["processing_stages"].is_a?(Hash) ? llm_meta["processing_stages"] : {}
    end

    def llm_processing_log(event)
      llm_meta = event.llm_comment_metadata.is_a?(Hash) ? event.llm_comment_metadata : {}
      Array(llm_meta["processing_log"])
    end

    def local_processing_stages(event)
      event_meta = event.metadata.is_a?(Hash) ? event.metadata : {}
      local = event_meta.dig("local_story_intelligence", "processing_stages")
      local.is_a?(Hash) ? local : {}
    rescue StandardError
      {}
    end

    def local_processing_log(event)
      event_meta = event.metadata.is_a?(Hash) ? event.metadata : {}
      Array(event_meta.dig("local_story_intelligence", "processing_log"))
    rescue StandardError
      []
    end

    def merge_stage_hashes(primary, secondary)
      base = primary.is_a?(Hash) ? primary.deep_dup : {}
      overlay = secondary.is_a?(Hash) ? secondary.deep_dup : {}
      base.deep_merge(overlay)
    rescue StandardError
      secondary.is_a?(Hash) ? secondary : {}
    end

    def llm_comment_estimated_seconds(event:, include_queue: false)
      base = 18
      queue_factor = include_queue ? (ai_queue_size * 4) : 0
      attempt_factor = event.llm_comment_attempts.to_i * 6
      preprocess_factor = story_local_context_preprocess_penalty(event: event)
      (base + queue_factor + attempt_factor + preprocess_factor).clamp(10, 240)
    end

    def story_local_context_preprocess_penalty(event:)
      metadata = event.metadata.is_a?(Hash) ? event.metadata : {}
      has_context = metadata["local_story_intelligence"].is_a?(Hash) ||
        metadata["ocr_text"].to_s.present? ||
        Array(metadata["content_signals"]).any?
      return 0 if has_context

      media_type = event.media&.blob&.content_type.to_s.presence || metadata["media_content_type"].to_s
      media_type.start_with?("image/") ? 16 : 8
    rescue StandardError
      0
    end

    def ai_queue_size
      queue_inspector.queue_size
    end
  end
end
