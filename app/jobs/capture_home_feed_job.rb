class CaptureHomeFeedJob < ApplicationJob
  queue_as :sync

  def perform(instagram_account_id:, rounds: 4, delay_seconds: 45, max_new: 20)
    account = InstagramAccount.find(instagram_account_id)
    client = Instagram::Client.new(account: account)

    result = client.capture_home_feed_posts!(rounds: rounds, delay_seconds: delay_seconds, max_new: max_new)

    Turbo::StreamsChannel.broadcast_append_to(
      account,
      target: "notifications",
      partial: "shared/notification",
      locals: { kind: "notice", message: "Feed capture completed for #{account.username}: new=#{result[:new_posts]}, seen=#{result[:seen_posts]}." }
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

