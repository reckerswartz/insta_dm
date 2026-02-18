class GenerateLlmCommentJob < ApplicationJob
  queue_as :ai

  retry_on Net::OpenTimeout, Net::ReadTimeout, wait: :polynomially_longer, attempts: 3
  retry_on Errno::ECONNREFUSED, Errno::ECONNRESET, wait: :polynomially_longer, attempts: 3

  def perform(instagram_profile_event_id:, provider: "local", model: nil, requested_by: "system")
    requested_provider = provider.to_s
    provider = "local"
    event = InstagramProfileEvent.find(instagram_profile_event_id)
    return unless event.story_archive_item?

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
end
