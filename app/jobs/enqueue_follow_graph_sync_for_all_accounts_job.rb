class EnqueueFollowGraphSyncForAllAccountsJob < ApplicationJob
  queue_as :sync

  def perform
    InstagramAccount.find_each do |account|
      next if account.cookies.blank?
      next if account.username.blank?

      run = account.sync_runs.create!(kind: "follow_graph", status: "queued")
      SyncFollowGraphJob.perform_later(instagram_account_id: account.id, sync_run_id: run.id)
    rescue StandardError
      # best-effort; errors will be recorded by ApplicationJob failure logging
      next
    end
  end
end
