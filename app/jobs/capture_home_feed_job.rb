class CaptureHomeFeedJob < ApplicationJob
  queue_as :sync

  def perform(instagram_account_id:, rounds: 4, delay_seconds: 45, max_new: 20)
    account = InstagramAccount.find(instagram_account_id)
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
end
