class SyncFollowGraphJob < ApplicationJob
  queue_as :sync

  retry_on Selenium::WebDriver::Error::StaleElementReferenceError, wait: 3.seconds, attempts: 3

  def perform(instagram_account_id:, sync_run_id:)
    account = InstagramAccount.find(instagram_account_id)
    sync_run = account.sync_runs.find(sync_run_id)

    sync_run.update!(status: "running", started_at: Time.current, error_message: nil)
    broadcast_status(account: account, sync_run: sync_run)

    stats = Instagram::Client.new(account: account).sync_follow_graph!

    sync_run.update!(status: "succeeded", finished_at: Time.current, stats: stats)
    broadcast_status(account: account, sync_run: sync_run)
    broadcast_notice(account: account, message: "Follow graph sync complete: #{stats[:profiles_total]} profiles (mutuals: #{stats[:mutuals]}).")
  rescue StandardError => e
    account ||= InstagramAccount.where(id: instagram_account_id).first
    sync_run ||= account&.sync_runs&.where(id: sync_run_id)&.first

    sync_run&.update!(status: "failed", finished_at: Time.current, error_message: e.message)
    broadcast_status(account: account, sync_run: sync_run) if account && sync_run
    broadcast_alert(account: account, message: "Follow graph sync failed: #{e.message}") if account
    raise
  end

  private

  def broadcast_status(account:, sync_run:)
    Turbo::StreamsChannel.broadcast_replace_to(
      account,
      target: "sync_status",
      partial: "sync_runs/status",
      locals: { sync_run: sync_run }
    )
  end

  def broadcast_notice(account:, message:)
    Turbo::StreamsChannel.broadcast_append_to(
      account,
      target: "notifications",
      partial: "shared/notification",
      locals: { kind: "notice", message: message }
    )
  end

  def broadcast_alert(account:, message:)
    Turbo::StreamsChannel.broadcast_append_to(
      account,
      target: "notifications",
      partial: "shared/notification",
      locals: { kind: "alert", message: message }
    )
  end
end
