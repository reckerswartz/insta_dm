class GenerateLlmCommentJob < ApplicationJob
  queue_as :ai

  retry_on Net::OpenTimeout, Net::ReadTimeout, wait: :polynomially_longer, attempts: 3
  retry_on Errno::ECONNREFUSED, Errno::ECONNRESET, wait: :polynomially_longer, attempts: 3

  def perform(instagram_profile_event_id:, provider: "local", model: nil, requested_by: "system")
    requested_provider = provider.to_s
    provider = "local"
    event = InstagramProfileEvent.find(instagram_profile_event_id)
    return unless event.story_archive_item?
    account = event.instagram_profile&.instagram_account
    profile = event.instagram_profile

    if event.has_llm_generated_comment?
      event.update_columns(
        llm_comment_status: "completed",
        llm_comment_last_error: nil,
        updated_at: Time.current
      )

      Ops::StructuredLogger.info(
        event: "llm_comment.already_completed",
        payload: {
          event_id: event.id,
          instagram_profile_id: event.instagram_profile_id,
          requested_provider: requested_provider,
          requested_by: requested_by
        }
      )
      return
    end

    preparation = prepare_profile_context(profile: profile, account: account)
    persist_profile_preparation_snapshot(event: event, preparation: preparation)
    unless ActiveModel::Type::Boolean.new.cast(preparation[:ready_for_comment_generation] || preparation["ready_for_comment_generation"])
      reason_code = preparation[:reason_code].to_s.presence || preparation["reason_code"].to_s.presence || "profile_comment_preparation_not_ready"
      reason_text = preparation[:reason].to_s.presence || preparation["reason"].to_s.presence || "Profile context is not ready for grounded comment generation."
      raise InstagramProfileEvent::LocalStoryIntelligenceUnavailableError.new(
        reason_text,
        reason: reason_code,
        source: "profile_comment_preparation"
      )
    end

    event.mark_llm_comment_running!(job_id: job_id)
    result = event.generate_llm_comment!(provider: provider, model: model)

    Ops::StructuredLogger.info(
      event: "llm_comment.completed",
      payload: {
        event_id: event.id,
        instagram_profile_id: event.instagram_profile_id,
        provider: event.llm_comment_provider,
        requested_provider: requested_provider,
        model: event.llm_comment_model,
        relevance_score: event.llm_comment_relevance_score,
        requested_by: requested_by,
        source: result[:source]
      }
    )
  rescue InstagramProfileEvent::LocalStoryIntelligenceUnavailableError => e
    event&.mark_llm_comment_skipped!(message: e.message, reason: e.reason, source: e.source)

    Ops::StructuredLogger.warn(
      event: "llm_comment.skipped_no_context",
      payload: {
        event_id: event&.id,
        instagram_profile_id: event&.instagram_profile_id,
        provider: provider,
        requested_provider: requested_provider,
        model: model,
        requested_by: requested_by,
        reason: e.reason,
        source: e.source,
        error_message: e.message
      }
    )
  rescue StandardError => e
    event&.mark_llm_comment_failed!(error: e)

    Ops::StructuredLogger.error(
      event: "llm_comment.failed",
      payload: {
        event_id: event&.id,
        instagram_profile_id: event&.instagram_profile_id,
        provider: provider,
        requested_provider: requested_provider,
        model: model,
        requested_by: requested_by,
        error_class: e.class.name,
        error_message: e.message
      }
    )

    raise
  end

  private

  def prepare_profile_context(profile:, account:)
    return { ready_for_comment_generation: false, reason_code: "profile_missing", reason: "Profile missing for event." } unless profile && account

    Ai::ProfileCommentPreparationService.new(account: account, profile: profile).prepare!
  rescue StandardError => e
    {
      ready_for_comment_generation: false,
      reason_code: "profile_preparation_error",
      reason: e.message.to_s,
      error_class: e.class.name
    }
  end

  def persist_profile_preparation_snapshot(event:, preparation:)
    return unless event
    return unless preparation.is_a?(Hash)

    existing = event.llm_comment_metadata.is_a?(Hash) ? event.llm_comment_metadata.deep_dup : {}
    existing["profile_comment_preparation"] = preparation
    event.update_columns(llm_comment_metadata: existing, updated_at: Time.current)
  rescue StandardError
    nil
  end
end
