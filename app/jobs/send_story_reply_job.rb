class SendStoryReplyJob < ApplicationJob
  queue_as :story_replies

  retry_on Net::OpenTimeout, Net::ReadTimeout, wait: :polynomially_longer, attempts: 4
  retry_on Errno::ECONNRESET, Errno::ECONNREFUSED, wait: :polynomially_longer, attempts: 4

  def perform(
    instagram_account_id:,
    instagram_profile_id:,
    story_id:,
    reply_text:,
    story_metadata: {},
    downloaded_event_id: nil
  )
    account = InstagramAccount.find_by(id: instagram_account_id)
    profile = InstagramProfile.find_by(id: instagram_profile_id, instagram_account_id: instagram_account_id)
    return unless account && profile

    sid = story_id.to_s.strip
    text = reply_text.to_s.strip
    return if sid.blank? || text.blank?
    return if story_reply_sent?(profile: profile, story_id: sid)

    message = account.instagram_messages.create!(
      instagram_profile: profile,
      direction: "outgoing",
      body: text,
      status: "queued"
    )
    mark_delivery_status!(
      profile: profile,
      story_id: sid,
      status: "sending",
      extra: {
        "instagram_message_id" => message.id
      }
    )

    result = Messaging::IntegrationService.new.send_text!(
      recipient_id: profile.ig_user_id.presence || profile.username,
      text: text,
      context: {
        source: "story_auto_reply",
        story_id: sid
      }
    )

    message.update!(status: "sent", sent_at: Time.current, error_message: nil)

    profile.record_event!(
      kind: "story_reply_sent",
      external_id: "story_reply_sent:#{sid}",
      occurred_at: Time.current,
      metadata: normalized_story_metadata(story_metadata).merge(
        ai_reply_text: text,
        auto_reply: true,
        instagram_message_id: message.id,
        provider_message_id: result[:provider_message_id]
      )
    )
    mark_delivery_status!(
      profile: profile,
      story_id: sid,
      status: "sent",
      extra: {
        "sent_at" => Time.current.iso8601(3),
        "instagram_message_id" => message.id,
        "provider_message_id" => result[:provider_message_id]
      }
    )

    attach_reply_comment_to_downloaded_event!(downloaded_event_id: downloaded_event_id, comment_text: text)
  rescue StandardError => e
    if defined?(message) && message&.persisted?
      message.update!(status: "failed", error_message: e.message.to_s)
    end
    if defined?(profile) && profile && sid.present?
      mark_delivery_status!(
        profile: profile,
        story_id: sid,
        status: "failed",
        extra: {
          "failed_at" => Time.current.iso8601(3),
          "error_class" => e.class.name,
          "error_message" => e.message.to_s.byteslice(0, 280)
        }
      )
    end
    raise
  end

  private

  def story_reply_sent?(profile:, story_id:)
    profile.instagram_profile_events.where(kind: "story_reply_sent", external_id: "story_reply_sent:#{story_id}").exists?
  end

  def normalized_story_metadata(raw_metadata)
    data = raw_metadata.is_a?(Hash) ? raw_metadata : {}
    data.deep_stringify_keys
  rescue StandardError
    {}
  end

  def attach_reply_comment_to_downloaded_event!(downloaded_event_id:, comment_text:)
    return if downloaded_event_id.blank? || comment_text.blank?

    event = InstagramProfileEvent.find_by(id: downloaded_event_id)
    return unless event

    metadata = event.metadata.is_a?(Hash) ? event.metadata.deep_dup : {}
    metadata["reply_comment"] = comment_text.to_s
    event.update!(metadata: metadata)
  rescue StandardError
    nil
  end

  def mark_delivery_status!(profile:, story_id:, status:, extra:)
    event = profile.instagram_profile_events.find_by(kind: "story_reply_queued", external_id: "story_reply_queued:#{story_id}")
    return unless event

    metadata = event.metadata.is_a?(Hash) ? event.metadata.deep_dup : {}
    metadata["delivery_status"] = status.to_s
    metadata["delivery_updated_at"] = Time.current.iso8601(3)
    metadata.merge!(extra.to_h)
    event.update!(metadata: metadata)
  rescue StandardError
    nil
  end
end
