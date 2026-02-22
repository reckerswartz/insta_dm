class EnqueueAvatarSyncForAllAccountsJob < ApplicationJob
  include ScheduledAccountBatching

  queue_as :avatars

  DEFAULT_ACCOUNT_BATCH_SIZE = ENV.fetch("AVATAR_SYNC_ACCOUNT_BATCH_SIZE", "30").to_i.clamp(5, 160)
  CONTINUATION_WAIT_SECONDS = ENV.fetch("AVATAR_SYNC_CONTINUATION_WAIT_SECONDS", "2").to_i.clamp(1, 90)
  ACCOUNT_ENQUEUE_STAGGER_SECONDS = ENV.fetch("AVATAR_SYNC_ACCOUNT_ENQUEUE_STAGGER_SECONDS", "3").to_i.clamp(0, 120)
  ACCOUNT_ENQUEUE_JITTER_SECONDS = ENV.fetch("AVATAR_SYNC_ACCOUNT_ENQUEUE_JITTER_SECONDS", "2").to_i.clamp(0, 30)

  def perform(opts = nil, **kwargs)
    params = normalize_scheduler_params(
      opts,
      kwargs,
      limit: 500,
      batch_size: DEFAULT_ACCOUNT_BATCH_SIZE,
      cursor_id: nil
    )
    limit = params[:limit].to_i.clamp(1, 2000)
    batch = load_account_batch(
      scope: InstagramAccount.all,
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

      enqueue_account_job_with_delay!(
        job_class: DownloadMissingAvatarsJob,
        slot_index: enqueued,
        account_id: account.id,
        stagger_seconds: ACCOUNT_ENQUEUE_STAGGER_SECONDS,
        jitter_seconds: ACCOUNT_ENQUEUE_JITTER_SECONDS,
        args: {
          instagram_account_id: account.id,
          limit: limit
        }
      )
      enqueued += 1
    rescue StandardError
      next
    end

    continuation_job = nil
    if batch[:has_more]
      continuation_job = schedule_account_batch_continuation!(
        wait_seconds: CONTINUATION_WAIT_SECONDS,
        payload: {
          limit: limit,
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
