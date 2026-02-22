module InstagramAccounts
  class LlmCommentRequestService
    Result = Struct.new(:payload, :status, keyword_init: true)

    def initialize(account:, event_id:, provider:, model:, status_only:, force: false, regenerate_all: false, queue_inspector: LlmQueueInspector.new)
      @account = account
      @event_id = event_id
      @provider = provider.to_s
      @model = model
      @status_only = ActiveModel::Type::Boolean.new.cast(status_only)
      @regenerate_all = ActiveModel::Type::Boolean.new.cast(regenerate_all)
      @force = ActiveModel::Type::Boolean.new.cast(force) || @regenerate_all
      @queue_inspector = queue_inspector
    end

    def call
      event = InstagramProfileEvent.find(event_id)
      return not_found_result unless accessible_event?(event)

      completed_event = normalize_completed_event(event)
      if completed_event && !force
        return completed_status_result(completed_event) if status_only
        return completed_result(completed_event)
      end

      in_progress = normalize_in_progress_event(event)
      return in_progress if in_progress

      return status_result(event) if status_only

      enqueue_comment_job(event, force: force, regenerate_all: regenerate_all)
    rescue StandardError => e
      Result.new(payload: { error: e.message }, status: :unprocessable_entity)
    end

    private

    attr_reader :account, :event_id, :provider, :model, :status_only, :force, :regenerate_all, :queue_inspector

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
          llm_pipeline_step_rollup: pipeline_step_rollup(event),
          llm_pipeline_timing: pipeline_timing(event),
          llm_last_stage: merged_llm_last_stage(event),
          llm_manual_review_reason: llm_meta["manual_review_reason"].to_s.presence,
          llm_auto_post_allowed: ActiveModel::Type::Boolean.new.cast(llm_meta["auto_post_allowed"]),
          llm_workflow_status: workflow_status_for(event),
          llm_workflow_progress: workflow_progress_for(event)
        },
        status: :ok
      )
    end

    def normalize_completed_event(event)
      return nil unless event.has_llm_generated_comment?

      event.update_column(:llm_comment_status, "completed") if event.llm_comment_status.to_s != "completed"
      event
    end

    def normalize_in_progress_event(event)
      return nil unless event.llm_comment_in_progress?
      return in_progress_result(event) if parallel_pipeline_active?(event)

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

    def enqueue_comment_job(event, force: false, regenerate_all: false)
      event.with_lock do
        event.reload

        completed_event = normalize_completed_event(event)
        return completed_result(completed_event) if completed_event && !force

        in_progress = normalize_in_progress_event(event)
        return in_progress if in_progress

        reset_generation_state!(event, regenerate_all: regenerate_all) if force && event.has_llm_generated_comment?

        job = GenerateLlmCommentJob.perform_later(
          instagram_profile_event_id: event.id,
          provider: provider,
          model: model,
          requested_by: "dashboard_manual_request",
          regenerate_all: regenerate_all
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
            queue_estimate: llm_queue_estimate_payload,
            llm_processing_stages: merged_llm_processing_stages(event),
            llm_last_stage: merged_llm_last_stage(event),
            llm_workflow_status: workflow_status_for(event),
            llm_workflow_progress: workflow_progress_for(event),
            forced: force,
            regenerate_all: regenerate_all
          },
          status: :accepted
        )
      end
    end

    def reset_generation_state!(event, regenerate_all: false)
      existing_metadata = event.llm_comment_metadata.is_a?(Hash) ? event.llm_comment_metadata.deep_dup : {}
      next_metadata =
        if ActiveModel::Type::Boolean.new.cast(regenerate_all)
          {}
        else
          {
            "parallel_pipeline" => existing_metadata["parallel_pipeline"].is_a?(Hash) ? existing_metadata["parallel_pipeline"] : nil,
            "processing_stages" => existing_metadata["processing_stages"].is_a?(Hash) ? existing_metadata["processing_stages"] : nil,
            "processing_log" => Array(existing_metadata["processing_log"]).select { |row| row.is_a?(Hash) }.last(40),
            "profile_comment_preparation" => existing_metadata["profile_comment_preparation"].is_a?(Hash) ? existing_metadata["profile_comment_preparation"] : nil
          }.compact
        end

      event.update_columns(
        llm_generated_comment: nil,
        llm_comment_generated_at: nil,
        llm_comment_model: nil,
        llm_comment_provider: nil,
        llm_comment_relevance_score: nil,
        llm_comment_last_error: nil,
        llm_comment_status: "not_requested",
        llm_comment_metadata: next_metadata,
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
          queue_estimate: llm_queue_estimate_payload,
          llm_processing_stages: merged_llm_processing_stages(event),
          llm_processing_log: merged_llm_processing_log(event),
          llm_pipeline_step_rollup: pipeline_step_rollup(event),
          llm_pipeline_timing: pipeline_timing(event),
          llm_last_stage: merged_llm_last_stage(event),
          llm_workflow_status: workflow_status_for(event),
          llm_workflow_progress: workflow_progress_for(event)
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
          queue_estimate: llm_queue_estimate_payload,
          llm_processing_stages: merged_llm_processing_stages(event),
          llm_processing_log: merged_llm_processing_log(event),
          llm_pipeline_step_rollup: pipeline_step_rollup(event),
          llm_pipeline_timing: pipeline_timing(event),
          llm_last_stage: merged_llm_last_stage(event),
          llm_workflow_status: workflow_status_for(event),
          llm_workflow_progress: workflow_progress_for(event)
        },
        status: :ok
      )
    end

    def completed_status_result(event)
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
          llm_pipeline_step_rollup: pipeline_step_rollup(event),
          llm_pipeline_timing: pipeline_timing(event),
          llm_last_stage: merged_llm_last_stage(event),
          llm_workflow_status: workflow_status_for(event),
          llm_workflow_progress: workflow_progress_for(event)
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

    def pipeline_step_rollup(event)
      pipeline = parallel_pipeline(event)
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

    def pipeline_timing(event)
      pipeline = parallel_pipeline(event)
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
      queue_estimate = llm_queue_estimate_payload
      queue_wait_seconds = queue_estimate[:estimated_new_item_wait_seconds].to_f
      queue_total_seconds = queue_estimate[:estimated_new_item_total_seconds].to_f
      estimated_processing_seconds = [ queue_total_seconds - queue_wait_seconds, 20.0 ].max
      base = include_queue ? queue_total_seconds : estimated_processing_seconds
      base = 120.0 if base <= 0.0

      attempt_factor = event.llm_comment_attempts.to_i * 30
      preprocess_factor = story_local_context_preprocess_penalty(event: event)
      (base + attempt_factor + preprocess_factor).round.clamp(30, 1800)
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
      estimate_size = llm_queue_estimate_payload[:queue_size].to_i
      return estimate_size if estimate_size.positive?

      queue_inspector.queue_size
    end

    def llm_queue_estimate_payload
      return @llm_queue_estimate_payload if defined?(@llm_queue_estimate_payload)

      estimate = queue_inspector.queue_estimate
      return {} unless estimate.is_a?(Hash)

      @llm_queue_estimate_payload = estimate.deep_symbolize_keys
    rescue StandardError
      @llm_queue_estimate_payload = {}
    end

    def parallel_pipeline(event)
      llm_meta = event.llm_comment_metadata.is_a?(Hash) ? event.llm_comment_metadata : {}
      value = llm_meta["parallel_pipeline"]
      value.is_a?(Hash) ? value : {}
    rescue StandardError
      {}
    end

    def parallel_pipeline_active?(event)
      llm_meta = event.llm_comment_metadata.is_a?(Hash) ? event.llm_comment_metadata : {}
      pipeline = llm_meta["parallel_pipeline"]
      return false unless pipeline.is_a?(Hash)
      return false unless pipeline["run_id"].to_s.present?
      return false unless pipeline["status"].to_s == "running"

      # Treat stale pipelines as failed to avoid infinite in-progress states.
      updated_at = parse_time(pipeline["updated_at"]) || parse_time(pipeline["created_at"])
      return false if updated_at.present? && updated_at < 20.minutes.ago

      true
    rescue StandardError
      false
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

    def workflow_status_for(event)
      serializer = InstagramAccounts::StoryArchiveItemSerializer.new(event: event)
      serializer.send(:llm_workflow_status, event: event, llm_meta: (event.llm_comment_metadata.is_a?(Hash) ? event.llm_comment_metadata : {}), manual_send_status: serializer.send(:manual_send_status, event.metadata.is_a?(Hash) ? event.metadata : {}))
    rescue StandardError
      "queued"
    end

    def workflow_progress_for(event)
      serializer = InstagramAccounts::StoryArchiveItemSerializer.new(event: event)
      serializer.send(:llm_workflow_progress, event: event, llm_meta: (event.llm_comment_metadata.is_a?(Hash) ? event.llm_comment_metadata : {}), manual_send_status: serializer.send(:manual_send_status, event.metadata.is_a?(Hash) ? event.metadata : {}))
    rescue StandardError
      { completed: 0, total: 5, summary: "0/5 completed" }
    end
  end
end
