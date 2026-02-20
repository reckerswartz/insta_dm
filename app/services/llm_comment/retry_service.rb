# frozen_string_literal: true

module LlmComment
  # Service for handling retry logic for LLM comment generation
  # Extracted from GenerateLlmCommentJob to follow Single Responsibility Principle
  class RetryService
    PROFILE_PREPARATION_RETRY_REASON_CODES = %w[
      profile_missing
      profile_preparation_error
      insufficient_profile_data
      profile_analysis_incomplete
    ].freeze

    PROFILE_PREPARATION_RETRY_MAX_ATTEMPTS = 3

    def initialize(event:, reason_code:, requested_provider:, model:, requested_by:)
      @event = event
      @reason_code = reason_code.to_s
      @requested_provider = requested_provider
      @model = model
      @requested_by = requested_by
    end

    def call
      return failure_response("event_missing") unless event
      return failure_response("reason_not_retryable") unless retryable_reason?

      if retry_attempts_exhausted?
        failure_response("retry_attempts_exhausted")
      else
        enqueue_build_history_retry
      end
    rescue StandardError => e
      failure_response("retry_enqueue_failed", e.class.name, e.message)
    end

    private

    attr_reader :event, :reason_code, :requested_provider, :model, :requested_by

    def retryable_reason?
      PROFILE_PREPARATION_RETRY_REASON_CODES.include?(reason_code)
    end

    def retry_attempts_exhausted?
      current_attempts >= PROFILE_PREPARATION_RETRY_MAX_ATTEMPTS
    end

    def current_attempts
      retry_state["attempts"].to_i
    end

    def retry_state
      metadata = event.llm_comment_metadata.is_a?(Hash) ? event.llm_comment_metadata.deep_dup : {}
      metadata["profile_preparation_retry"].is_a?(Hash) ? metadata["profile_preparation_retry"].deep_dup : {}
    end

    def enqueue_build_history_retry
      profile = event.instagram_profile
      account = profile&.instagram_account
      return failure_response("profile_missing") unless profile && account

      history_result = BuildInstagramProfileHistoryJob.enqueue_with_resume_if_needed!(
        account: account,
        profile: profile,
        trigger_source: "story_comment_preparation_fallback",
        requested_by: "GenerateLlmCommentJob",
        resume_job: build_resume_job_payload
      )

      return failure_response(history_result[:reason]) unless job_accepted?(history_result)

      update_retry_state(history_result)
      success_response(history_result)
    end

    def build_resume_job_payload
      {
        job_class: GenerateLlmCommentJob,
        job_kwargs: {
          instagram_profile_event_id: event.id,
          provider: requested_provider,
          model: model,
          requested_by: "profile_preparation_retry:#{requested_by}"
        }
      }
    end

    def job_accepted?(history_result)
      ActiveModel::Type::Boolean.new.cast(history_result[:accepted])
    end

    def update_retry_state(history_result)
      metadata = event.llm_comment_metadata.is_a?(Hash) ? event.llm_comment_metadata.deep_dup : {}
      retry_state = metadata["profile_preparation_retry"].is_a?(Hash) ? metadata["profile_preparation_retry"].deep_dup : {}

      retry_state["attempts"] = current_attempts + 1
      retry_state["last_reason_code"] = reason_code
      retry_state["last_skipped_at"] = Time.current.iso8601(3)
      retry_state["last_enqueued_at"] = Time.current.iso8601(3)
      retry_state["next_run_at"] = history_result[:next_run_at].to_s.presence
      retry_state["job_id"] = history_result[:job_id].to_s.presence
      retry_state["build_history_action_log_id"] = history_result[:action_log_id].to_i if history_result[:action_log_id].present?
      retry_state["source"] = "GenerateLlmCommentJob"
      retry_state["mode"] = "build_history_fallback"

      metadata["profile_preparation_retry"] = retry_state
      event.update_columns(llm_comment_metadata: metadata, updated_at: Time.current)
    end

    def success_response(history_result)
      {
        queued: true,
        reason: "build_history_fallback_registered",
        job_id: history_result[:job_id].to_s,
        action_log_id: history_result[:action_log_id],
        next_run_at: history_result[:next_run_at].to_s
      }
    end

    def failure_response(reason, error_class = nil, error_message = nil)
      response = {
        queued: false,
        reason: reason
      }

      response[:error_class] = error_class if error_class
      response[:error_message] = error_message if error_message

      response
    end
  end
end
