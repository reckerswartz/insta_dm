class CaptureHomeFeedJob < ApplicationJob
  queue_as :sync

  FEED_CAPTURE_MIN_INTERVAL_SECONDS = ENV.fetch("FEED_CAPTURE_MIN_INTERVAL_SECONDS", "300").to_i.clamp(30, 3600)

  def perform(instagram_account_id:, rounds: 4, delay_seconds: 45, max_new: 20)
    account = InstagramAccount.find(instagram_account_id)
    unless claim_capture_slot!(account: account)
      Ops::StructuredLogger.info(
        event: "feed_capture_home.skipped_recent_run",
        payload: {
          instagram_account_id: account.id,
          active_job_id: job_id,
          min_interval_seconds: FEED_CAPTURE_MIN_INTERVAL_SECONDS
        }
      )
      return
    end

    client = Instagram::Client.new(account: account)

    result = client.capture_home_feed_posts!(rounds: rounds, delay_seconds: delay_seconds, max_new: max_new)
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
        rounds: rounds.to_i,
        delay_seconds: delay_seconds.to_i,
        max_new: max_new.to_i,
        seen_posts: result[:seen_posts].to_i,
        new_posts: result[:new_posts].to_i,
        updated_posts: result[:updated_posts].to_i,
        queued_actions: result[:queued_actions].to_i,
        skipped_posts: result[:skipped_posts].to_i,
        skipped_reasons: result[:skipped_reasons].is_a?(Hash) ? result[:skipped_reasons] : {}
      }
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
    claimed = false
    now = Time.current

    account.with_lock do
      last_run_at = account.continuous_processing_last_feed_sync_enqueued_at
      if last_run_at.present? && last_run_at > (now - FEED_CAPTURE_MIN_INTERVAL_SECONDS.seconds)
        next
      end

      account.update_columns(
        continuous_processing_last_feed_sync_enqueued_at: now,
        updated_at: Time.current
      )
      claimed = true
    end

    claimed
  rescue StandardError
    false
  end
end
