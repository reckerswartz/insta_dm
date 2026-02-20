module InstagramAccounts
  class TechnicalDetailsPayloadService
    Result = Struct.new(:payload, :status, keyword_init: true)

    def initialize(account:, event_id:)
      @account = account
      @event_id = event_id
    end

    def call
      event = InstagramProfileEvent.find(event_id)
      return not_found_result unless event.instagram_profile&.instagram_account_id == account.id

      llm_meta = event.llm_comment_metadata.is_a?(Hash) ? event.llm_comment_metadata : {}
      stored_details = llm_meta["technical_details"] || llm_meta[:technical_details]
      technical_details = hydrate_technical_details(event: event, technical_details: stored_details)

      Result.new(
        payload: {
          event_id: event.id,
          has_llm_comment: event.has_llm_generated_comment?,
          llm_comment: event.llm_generated_comment,
          generated_at: event.llm_comment_generated_at,
          model: event.llm_comment_model,
          provider: event.llm_comment_provider,
          status: event.llm_comment_status,
          relevance_score: event.llm_comment_relevance_score,
          last_error: event.llm_comment_last_error,
          timeline: story_timeline_for(event: event),
          technical_details: technical_details
        },
        status: :ok
      )
    rescue StandardError => e
      Result.new(payload: { error: e.message }, status: :unprocessable_entity)
    end

    private

    attr_reader :account, :event_id

    def not_found_result
      Result.new(payload: { error: "Event not found or not accessible" }, status: :not_found)
    end

    def hydrate_technical_details(event:, technical_details:)
      current = technical_details.is_a?(Hash) ? technical_details.deep_stringify_keys : {}
      has_required_sections =
        current["local_story_intelligence"].is_a?(Hash) &&
        current["analysis"].is_a?(Hash) &&
        current["prompt_engineering"].is_a?(Hash)
      return current if has_required_sections

      context = event.send(:build_comment_context)
      generated = event.send(:capture_technical_details, context)
      generated_hash = generated.is_a?(Hash) ? generated.deep_stringify_keys : {}
      generated_hash.deep_merge(current)
    rescue StandardError
      current
    end

    def story_timeline_for(event:)
      metadata = event.metadata.is_a?(Hash) ? event.metadata : {}
      story = event.instagram_stories.order(taken_at: :desc, id: :desc).first

      {
        story_posted_at: metadata["upload_time"].presence || metadata["taken_at"].presence || story&.taken_at&.iso8601,
        downloaded_to_system_at: metadata["downloaded_at"].presence || event.occurred_at&.iso8601 || event.created_at&.iso8601,
        event_detected_at: event.detected_at&.iso8601
      }
    end
  end
end
