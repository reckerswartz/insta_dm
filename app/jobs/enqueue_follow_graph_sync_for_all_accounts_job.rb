class EnqueueFollowGraphSyncForAllAccountsJob < ApplicationJob
  include ScheduledAccountBatching

  queue_as :sync

  DEFAULT_ACCOUNT_BATCH_SIZE = ENV.fetch("FOLLOW_GRAPH_SYNC_ACCOUNT_BATCH_SIZE", "20").to_i.clamp(5, 120)
  CONTINUATION_WAIT_SECONDS = ENV.fetch("FOLLOW_GRAPH_SYNC_CONTINUATION_WAIT_SECONDS", "3").to_i.clamp(1, 90)
  ACCOUNT_ENQUEUE_STAGGER_SECONDS = ENV.fetch("FOLLOW_GRAPH_SYNC_ACCOUNT_ENQUEUE_STAGGER_SECONDS", "5").to_i.clamp(0, 120)
  ACCOUNT_ENQUEUE_JITTER_SECONDS = ENV.fetch("FOLLOW_GRAPH_SYNC_ACCOUNT_ENQUEUE_JITTER_SECONDS", "3").to_i.clamp(0, 30)

  def perform(opts = nil, **kwargs)
    params = normalize_scheduler_params(opts, kwargs, batch_size: DEFAULT_ACCOUNT_BATCH_SIZE, cursor_id: nil)
    batch = load_account_batch(
      scope: InstagramAccount.where.not(username: [ nil, "" ]),
      cursor_id: params[:cursor_id],
      batch_size: params[:batch_size]
    )

    enqueued = 0
    scheduler_lease_skipped = 0
    batch[:accounts].each do |account|
      next if account.cookies.blank?

      scheduler_lease = AutonomousSchedulerLease.reserve!(account: account, source: self.class.name)
      unless scheduler_lease.reserved
        scheduler_lease_skipped += 1
        next
      end

      run = account.sync_runs.create!(kind: "follow_graph", status: "queued")
      enqueue_account_job_with_delay!(
        job_class: SyncFollowGraphJob,
        slot_index: enqueued,
        account_id: account.id,
        stagger_seconds: ACCOUNT_ENQUEUE_STAGGER_SECONDS,
        jitter_seconds: ACCOUNT_ENQUEUE_JITTER_SECONDS,
        args: {
          instagram_account_id: account.id,
          sync_run_id: run.id
        }
      )
      enqueued += 1
    rescue StandardError
      # best-effort; errors will be recorded by ApplicationJob failure logging
      next
    end

    continuation_job = nil
    if batch[:has_more]
      continuation_job = schedule_account_batch_continuation!(
        wait_seconds: CONTINUATION_WAIT_SECONDS,
        payload: {
          batch_size: batch[:batch_size],
          cursor_id: batch[:next_cursor_id]
        }
      )
    end

    {
      accounts_enqueued: enqueued,
      scanned_accounts: batch[:accounts].length,
      scheduler_lease_skipped: scheduler_lease_skipped,
      continuation_job_id: continuation_job&.job_id
    }
  end
end
