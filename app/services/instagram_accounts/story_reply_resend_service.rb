module InstagramAccounts
  class StoryReplyResendService
    Result = Struct.new(:payload, :status, keyword_init: true)

    def initialize(account:, event_id:, comment_text:)
      @account = account
      @event_id = event_id
      @comment_text = comment_text.to_s
    end

    def call
      event = InstagramProfileEvent.find(event_id)
      return not_found_result unless accessible_event?(event)

      profile = event.instagram_profile
      return Result.new(payload: { error: "Profile is missing for this story event" }, status: :unprocessable_entity) if profile.blank?

      message_text = resolved_message_text(event: event)
      return Result.new(payload: { error: "No saved comment text is available for resend" }, status: :unprocessable_entity) if message_text.blank?

      story_id = story_id_for(event: event)
      return Result.new(payload: { error: "Story id is missing for this event" }, status: :unprocessable_entity) if story_id.blank?

      recipient_id = profile.ig_user_id.to_s.presence || profile.username.to_s.presence
      return Result.new(payload: { error: "Profile recipient id is unavailable" }, status: :unprocessable_entity) if recipient_id.blank?

      response = messaging_service.send_text!(
        recipient_id: recipient_id,
        text: message_text,
        context: {
          source: "story_archive_manual_resend",
          story_id: story_id
        }
      )

      message = account.instagram_messages.create!(
        instagram_profile: profile,
        direction: "outgoing",
        body: message_text,
        status: "sent",
        sent_at: Time.current
      )

      profile.record_event!(
        kind: "story_reply_resent",
        external_id: "story_reply_resent:#{story_id}:#{Time.current.utc.iso8601(6)}",
        occurred_at: Time.current,
        metadata: story_metadata(event: event).merge(
          resent_comment_text: message_text,
          instagram_message_id: message.id,
          provider_message_id: response[:provider_message_id]
        )
      )

      persist_reply_on_archive_event!(event: event, comment_text: message_text)

      Result.new(
        payload: {
          success: true,
          status: "sent",
          event_id: event.id,
          story_id: story_id,
          instagram_message_id: message.id,
          provider_message_id: response[:provider_message_id]
        },
        status: :ok
      )
    rescue StandardError => e
      persist_failed_resend_event(event: event, error: e)
      Result.new(payload: { error: e.message.to_s }, status: :unprocessable_entity)
    end

    private

    attr_reader :account, :event_id, :comment_text

    def accessible_event?(event)
      event.story_archive_item? && event.instagram_profile&.instagram_account_id == account.id
    end

    def not_found_result
      Result.new(payload: { error: "Event not found or not accessible" }, status: :not_found)
    end

    def resolved_message_text(event:)
      candidate = comment_text.strip
      return candidate if candidate.present?

      meta = story_metadata(event: event)
      saved = meta["reply_comment"].to_s.strip
      return saved if saved.present?

      event.llm_generated_comment.to_s.strip
    end

    def story_id_for(event:)
      story_metadata(event: event)["story_id"].to_s.strip
    end

    def story_metadata(event:)
      event.metadata.is_a?(Hash) ? event.metadata : {}
    end

    def messaging_service
      @messaging_service ||= Messaging::IntegrationService.new
    end

    def persist_reply_on_archive_event!(event:, comment_text:)
      event.with_lock do
        event.reload
        metadata = story_metadata(event: event).deep_dup
        metadata["reply_comment"] = comment_text.to_s
        metadata["manual_resend_last_at"] = Time.current.utc.iso8601(3)
        event.update!(metadata: metadata)
      end
    rescue StandardError
      nil
    end

    def persist_failed_resend_event(event:, error:)
      return if event.blank?

      profile = event.instagram_profile
      return if profile.blank?

      message_text = resolved_message_text(event: event)
      if message_text.present?
        account.instagram_messages.create!(
          instagram_profile: profile,
          direction: "outgoing",
          body: message_text,
          status: "failed",
          error_message: error.message.to_s
        )
      end

      profile.record_event!(
        kind: "story_reply_resend_failed",
        external_id: "story_reply_resend_failed:#{story_id_for(event: event)}:#{Time.current.utc.iso8601(6)}",
        occurred_at: Time.current,
        metadata: story_metadata(event: event).merge(
          resend_error_class: error.class.name,
          resend_error_message: error.message.to_s
        )
      )
    rescue StandardError
      nil
    end
  end
end
