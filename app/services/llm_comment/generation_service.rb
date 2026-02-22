# frozen_string_literal: true

module LlmComment
  # Service for handling LLM comment generation workflow
  # Extracted from GenerateLlmCommentJob to follow Single Responsibility Principle
  class GenerationService
    include ActiveModel::Validations

    attr_reader :event, :provider, :model, :requested_by, :result, :regenerate_all

    def initialize(instagram_profile_event_id:, provider: "local", model: nil, requested_by: "system", regenerate_all: false)
      @instagram_profile_event_id = instagram_profile_event_id
      @provider = provider.to_s
      @model = model
      @requested_by = requested_by
      @regenerate_all = ActiveModel::Type::Boolean.new.cast(regenerate_all)
      @event = InstagramProfileEvent.find(instagram_profile_event_id)
    end

    def call
      return skip_if_not_story_archive_item unless event.story_archive_item?
      return skip_if_already_completed if event.has_llm_generated_comment?
      return self unless claim_generation_slot!
      return skip_if_already_completed if @already_completed_during_claim

      prepare_profile_context
      persist_profile_preparation_snapshot
      generate_comment
      log_pipeline_enqueued

      self
    rescue InstagramProfileEvent::LocalStoryIntelligenceUnavailableError => e
      handle_policy_skip(e)
    rescue StandardError => e
      handle_generation_error(e)
      raise
    end

    private

    attr_reader :instagram_profile_event_id, :profile_preparation

    def skip_if_not_story_archive_item
      log_skip("not_story_archive_item", "Event is not a story archive item")
      self
    end

    def skip_if_already_completed
      event.update_columns(
        llm_comment_status: "completed",
        llm_comment_last_error: nil,
        updated_at: Time.current
      )

      log_pipeline_enqueued(already_completed: true)
      self
    end

    def prepare_profile_context
      @profile_preparation = ProfileContextPreparationService.new(
        profile: event.instagram_profile,
        account: event.instagram_profile&.instagram_account
      ).prepare!
    end

    def persist_profile_preparation_snapshot
      return unless profile_preparation.is_a?(Hash)

      event.with_lock do
        event.reload
        existing = event.llm_comment_metadata.is_a?(Hash) ? event.llm_comment_metadata.deep_dup : {}
        existing["profile_comment_preparation"] = profile_preparation
        event.update_columns(llm_comment_metadata: existing, updated_at: Time.current)
      end
    rescue StandardError
      nil
    end

    def enqueue_parallel_pipeline
      @result = ParallelPipelineOrchestrator.new(
        event: event,
        provider: @provider,
        model: @model,
        requested_by: @requested_by,
        source_job_id: Current.active_job_id,
        regenerate_all: regenerate_all
      ).call
    end

    # Backward-compatible seam used by existing specs and callers.
    def generate_comment
      enqueue_parallel_pipeline
    end

    def claim_generation_slot!
      active_job = Current.active_job_id.to_s
      claimed = false

      event.with_lock do
        event.reload
        if event.has_llm_generated_comment?
          @already_completed_during_claim = true
          event.update_columns(
            llm_comment_status: "completed",
            llm_comment_last_error: nil,
            updated_at: Time.current
          )
          next
        end

        # Allow queued jobs to be claimed by a newer job id (for deferred/re-enqueued runs).
        if event.llm_comment_status.to_s == "running" &&
            event.llm_comment_job_id.to_s.present? &&
            event.llm_comment_job_id.to_s != active_job
          Ops::StructuredLogger.info(
            event: "llm_comment.duplicate_job_skipped",
            payload: {
              event_id: event.id,
              active_job_id: active_job,
              claimed_job_id: event.llm_comment_job_id.to_s,
              instagram_profile_id: event.instagram_profile_id
            }
          )
          next
        end

        event.mark_llm_comment_running!(job_id: active_job)
        claimed = true
      end

      claimed
    rescue StandardError => e
      Ops::StructuredLogger.error(
        event: "llm_comment.claim_slot_failed",
        payload: {
          event_id: event&.id,
          instagram_profile_id: event&.instagram_profile_id,
          active_job_id: active_job,
          error_class: e.class.name,
          error_message: e.message.to_s
        }
      )
      raise
    end

    def log_pipeline_enqueued(already_completed: false)
      payload = build_pipeline_log_payload(already_completed: already_completed)

      Ops::StructuredLogger.info(
        event: already_completed ? "llm_comment.already_completed" : "llm_comment.parallel_pipeline_enqueued",
        payload: payload
      )
    end

    def build_pipeline_log_payload(already_completed:)
      base_payload = {
        event_id: event.id,
        instagram_profile_id: event.instagram_profile_id,
        requested_provider: @provider,
        requested_by: @requested_by,
        regenerate_all: regenerate_all
      }
      result_payload = @result.is_a?(Hash) ? @result : {}

      if already_completed
        base_payload
      else
        base_payload.merge(
          provider: @provider,
          model: @model,
          parallel_pipeline_run_id: result_payload[:run_id].to_s.presence,
          pipeline_status: result_payload[:status].to_s.presence
        )
      end
    end

    def handle_policy_skip(error)
      event.mark_llm_comment_skipped!(
        message: error.message,
        reason: error.reason,
        source: error.source
      )

      Ops::StructuredLogger.warn(
        event: "llm_comment.skipped_policy_block",
        payload: {
          event_id: event&.id,
          instagram_profile_id: event&.instagram_profile_id,
          provider: @provider,
          requested_provider: @provider,
          model: @model,
          requested_by: @requested_by,
          reason: error.reason,
          source: error.source,
          error_message: error.message
        }
      )

      self
    end

    def handle_generation_error(error)
      event.mark_llm_comment_failed!(error: error)

      Ops::StructuredLogger.error(
        event: "llm_comment.failed",
        payload: {
          event_id: event&.id,
          instagram_profile_id: event&.instagram_profile_id,
          provider: @provider,
          requested_provider: @provider,
          model: @model,
          requested_by: @requested_by,
          error_class: error.class.name,
          error_message: error.message
        }
      )

      self
    end

    def log_skip(reason_code, message)
      Ops::StructuredLogger.info(
        event: "llm_comment.skipped",
        payload: {
          event_id: event.id,
          instagram_profile_id: event.instagram_profile_id,
          reason_code: reason_code,
          reason: message,
          requested_provider: @provider,
          requested_by: @requested_by
        }
      )
    end
  end
end
