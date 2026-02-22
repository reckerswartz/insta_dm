class CaptureHomeFeedJob < ApplicationJob
  queue_as :sync

  FEED_CAPTURE_MIN_INTERVAL_SECONDS = FeedCaptureThrottle.min_interval_seconds

  def perform(
    instagram_account_id:,
    rounds: 4,
    delay_seconds: 45,
    max_new: 20,
    slot_claimed: false,
    trigger_source: "unknown",
    starting_max_id: nil
  )
    account = InstagramAccount.find(instagram_account_id)
    claimed_upstream = ActiveModel::Type::Boolean.new.cast(slot_claimed)
    rounds_i = rounds.to_i.clamp(1, 12)
    delay_i = delay_seconds.to_i.clamp(10, 120)
    max_new_i = max_new.to_i.clamp(1, 200)
    start_cursor = starting_max_id.to_s.strip.presence

    unless claimed_upstream || claim_capture_slot!(account: account)
      Ops::StructuredLogger.info(
        event: "feed_capture_home.skipped_recent_run",
        payload: {
          instagram_account_id: account.id,
          active_job_id: job_id,
          min_interval_seconds: FEED_CAPTURE_MIN_INTERVAL_SECONDS
        }
      )

      FeedCaptureActivityLog.append!(
        account: account,
        status: "skipped",
        source: trigger_source,
        message: "Skipped feed capture job #{job_id}: a capture run was queued in the last #{FEED_CAPTURE_MIN_INTERVAL_SECONDS} seconds."
      )
      return
    end

    FeedCaptureActivityLog.append!(
      account: account,
      status: "running",
      source: trigger_source,
      message: "Started feed capture job #{job_id} (rounds=#{rounds_i}, delay=#{delay_i}s, max_new=#{max_new_i}, cursor=#{start_cursor || 'start'})."
    )

    client = Instagram::Client.new(account: account)

    FeedCaptureActivityLog.append!(
      account: account,
      status: "running",
      source: trigger_source,
      message: "Feed capture job #{job_id} is collecting and processing home feed posts."
    )

    result = client.capture_home_feed_posts!(
      rounds: 1,
      delay_seconds: delay_i,
      max_new: max_new_i,
      starting_max_id: start_cursor
    )

    continuation_job = enqueue_continuation_if_needed(
      account: account,
      trigger_source: trigger_source,
      rounds_remaining: rounds_i - 1,
      delay_seconds: delay_i,
      max_new: [ max_new_i - result[:new_posts].to_i, 1 ].max,
      next_cursor: result[:next_max_id]
    )
    skipped_summary =
      if result[:skipped_reasons].is_a?(Hash) && result[:skipped_reasons].any?
        result[:skipped_reasons].map { |reason, count| "#{reason}=#{count}" }.join(", ")
      else
        "none"
      end

    Ops::StructuredLogger.info(
      event: "feed_capture_home.job_completed",
      payload: {
        instagram_account_id: account.id,
        active_job_id: job_id,
        rounds: rounds_i,
        delay_seconds: delay_i,
        max_new: max_new_i,
        starting_max_id: start_cursor,
        seen_posts: result[:seen_posts].to_i,
        new_posts: result[:new_posts].to_i,
        updated_posts: result[:updated_posts].to_i,
        queued_actions: result[:queued_actions].to_i,
        skipped_posts: result[:skipped_posts].to_i,
        skipped_reasons: result[:skipped_reasons].is_a?(Hash) ? result[:skipped_reasons] : {},
        next_max_id: result[:next_max_id].to_s.presence,
        more_available: ActiveModel::Type::Boolean.new.cast(result[:more_available]),
        continuation_enqueued: continuation_job.present?,
        continuation_job_id: continuation_job&.job_id
      }
    )

    FeedCaptureActivityLog.append!(
      account: account,
      status: "succeeded",
      source: trigger_source,
      message: "Completed feed capture job #{job_id}: new=#{result[:new_posts].to_i}, updated=#{result[:updated_posts].to_i}, queued=#{result[:queued_actions].to_i}, seen=#{result[:seen_posts].to_i}, skipped=#{result[:skipped_posts].to_i}, next_cursor=#{result[:next_max_id].to_s.presence || 'none'}, continuation=#{continuation_job.present? ? 'yes' : 'no'}."
    )

    Turbo::StreamsChannel.broadcast_append_to(
      account,
      target: "notifications",
      partial: "shared/notification",
      locals: {
        kind: "notice",
        message: "Feed capture completed for #{account.username}: new=#{result[:new_posts]}, updated=#{result[:updated_posts]}, queued=#{result[:queued_actions]}, seen=#{result[:seen_posts]}, skipped=#{result[:skipped_posts]} (#{skipped_summary})."
      }
    )
  rescue StandardError => e
    account ||= InstagramAccount.where(id: instagram_account_id).first
    FeedCaptureActivityLog.append!(
      account: account,
      status: "failed",
      source: trigger_source,
      message: "Feed capture job #{job_id} failed: #{e.class}: #{e.message}"
    ) if account
    Turbo::StreamsChannel.broadcast_append_to(
      account,
      target: "notifications",
      partial: "shared/notification",
      locals: { kind: "alert", message: "Feed capture failed: #{e.message}" }
    ) if account
    raise
  end

  private

  def claim_capture_slot!(account:)
    FeedCaptureThrottle.reserve!(account: account).reserved
  end

  def enqueue_continuation_if_needed(account:, trigger_source:, rounds_remaining:, delay_seconds:, max_new:, next_cursor:)
    return nil if rounds_remaining.to_i <= 0
    return nil if max_new.to_i <= 0
    cursor = next_cursor.to_s.strip
    return nil if cursor.blank?

    self.class.set(wait: delay_seconds.to_i.clamp(10, 120).seconds).perform_later(
      instagram_account_id: account.id,
      rounds: rounds_remaining.to_i,
      delay_seconds: delay_seconds.to_i,
      max_new: max_new.to_i,
      slot_claimed: true,
      trigger_source: trigger_source,
      starting_max_id: cursor
    )
  rescue StandardError => e
    Ops::StructuredLogger.warn(
      event: "feed_capture_home.continuation_enqueue_failed",
      payload: {
        instagram_account_id: account.id,
        active_job_id: job_id,
        error_class: e.class.name,
        error_message: e.message.to_s.byteslice(0, 220)
      }
    )
    nil
  end
end
