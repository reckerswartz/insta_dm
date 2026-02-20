class EnqueueRecentProfilePostScansForAllAccountsJob < ApplicationJob
  include ScheduledAccountBatching

  queue_as :post_downloads

  DEFAULT_ACCOUNT_BATCH_SIZE = ENV.fetch("PROFILE_SCAN_ACCOUNT_BATCH_SIZE", "25").to_i.clamp(5, 120)
  CONTINUATION_WAIT_SECONDS = ENV.fetch("PROFILE_SCAN_CONTINUATION_WAIT_SECONDS", "3").to_i.clamp(1, 90)

  # Accept a single hash (e.g. from Sidekiq cron/schedule) or keyword args from perform_later(...)
  def perform(opts = nil, **kwargs)
    params = normalize_scheduler_params(
      opts,
      kwargs,
      limit_per_account: 8,
      posts_limit: 3,
      comments_limit: 8,
      batch_size: DEFAULT_ACCOUNT_BATCH_SIZE,
      cursor_id: nil
    )
    limit_per_account = params[:limit_per_account].to_i.clamp(1, 30)
    posts_limit_i = params[:posts_limit].to_i.clamp(1, 3)
    comments_limit_i = params[:comments_limit].to_i.clamp(1, 20)
    batch = load_account_batch(
      scope: InstagramAccount.all,
      cursor_id: params[:cursor_id],
      batch_size: params[:batch_size]
    )

    enqueued_accounts = 0

    batch[:accounts].each do |account|
      next if account.cookies.blank?

      EnqueueRecentProfilePostScansForAccountJob.perform_later(
        instagram_account_id: account.id,
        limit_per_account: limit_per_account,
        posts_limit: posts_limit_i,
        comments_limit: comments_limit_i
      )
      enqueued_accounts += 1
    rescue StandardError => e
      Ops::StructuredLogger.warn(
        event: "profile_scan.all_accounts_enqueue_failed",
        payload: {
          account_id: account.id,
          error_class: e.class.name,
          error_message: e.message
        }
      )
      next
    end

    continuation_job = nil
    if batch[:has_more]
      continuation_job = schedule_account_batch_continuation!(
        wait_seconds: CONTINUATION_WAIT_SECONDS,
        payload: {
          limit_per_account: limit_per_account,
          posts_limit: posts_limit_i,
          comments_limit: comments_limit_i,
          batch_size: batch[:batch_size],
          cursor_id: batch[:next_cursor_id]
        }
      )
    end

    Ops::StructuredLogger.info(
      event: "profile_scan.all_accounts_batch_enqueued",
      payload: {
        accounts_enqueued: enqueued_accounts,
        scanned_accounts: batch[:accounts].length,
        limit_per_account: limit_per_account,
        posts_limit: posts_limit_i,
        comments_limit: comments_limit_i,
        batch_size: batch[:batch_size],
        continuation_enqueued: continuation_job.present?,
        continuation_job_id: continuation_job&.job_id
      }
    )

    {
      accounts_enqueued: enqueued_accounts,
      scanned_accounts: batch[:accounts].length,
      continuation_job_id: continuation_job&.job_id
    }
  end
end
