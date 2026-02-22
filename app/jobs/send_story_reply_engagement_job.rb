# frozen_string_literal: true

class SendStoryReplyEngagementJob < ApplicationJob
  queue_as Ops::AiServiceQueueRegistry.queue_symbol_for(:story_engagement_actions)

  MIN_INTERVAL_SECONDS = ENV.fetch("STORY_REPLY_MIN_INTERVAL_SECONDS", "2").to_i.clamp(0, 30)

  def perform(instagram_account_id:, event_id:, comment_text:, requested_by: "manual_send", defer_attempt: 0)
    account = InstagramAccount.find_by(id: instagram_account_id)
    event = InstagramProfileEvent.includes(:instagram_profile).find_by(id: event_id)
    return unless account && event && event.instagram_profile&.instagram_account_id == account.id

    if (remaining = throttle_seconds_remaining(account_id: account.id)).positive?
      mark_queued_waiting_throttle!(event: event, wait_seconds: remaining)
      self.class.set(wait: remaining.seconds).perform_later(
        instagram_account_id: account.id,
        event_id: event.id,
        comment_text: comment_text.to_s,
        requested_by: requested_by.to_s,
        defer_attempt: defer_attempt.to_i + 1
      )
      return
    end

    mark_throttle_execution!(account_id: account.id)
    InstagramAccounts::StoryReplyResendService.new(
      account: account,
      event_id: event.id,
      comment_text: comment_text.to_s
    ).call
  end

  private

  def throttle_seconds_remaining(account_id:)
    return 0 unless MIN_INTERVAL_SECONDS.positive?

    key = throttle_cache_key(account_id: account_id)
    last_at = Rails.cache.read(key)
    return 0 unless last_at.is_a?(Time)

    delta = MIN_INTERVAL_SECONDS - (Time.current.to_f - last_at.to_f)
    delta.positive? ? delta.ceil : 0
  rescue StandardError
    0
  end

  def mark_throttle_execution!(account_id:)
    return unless MIN_INTERVAL_SECONDS.positive?

    Rails.cache.write(throttle_cache_key(account_id: account_id), Time.current, expires_in: 2.minutes)
  rescue StandardError
    nil
  end

  def throttle_cache_key(account_id:)
    "story_reply_engagement:last_exec:#{account_id}"
  end

  def mark_queued_waiting_throttle!(event:, wait_seconds:)
    metadata = event.metadata.is_a?(Hash) ? event.metadata.deep_dup : {}
    metadata["manual_send_status"] = "queued"
    metadata["manual_send_reason"] = "rate_limit_guard"
    metadata["manual_send_message"] = "Queued due to engagement throttle. Retrying in #{wait_seconds}s."
    metadata["manual_send_updated_at"] = Time.current.utc.iso8601(3)
    event.update_columns(metadata: metadata, updated_at: Time.current)

    ActionCable.server.broadcast(
      "story_reply_status_#{event.instagram_profile.instagram_account_id}",
      {
        event_id: event.id,
        story_id: metadata["story_id"].to_s,
        status: "queued",
        reason: "rate_limit_guard",
        message: metadata["manual_send_message"],
        updated_at: metadata["manual_send_updated_at"]
      }.compact
    )
  rescue StandardError
    nil
  end
end
