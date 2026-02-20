require_dependency "scheduled_account_batching"

class EnqueueContinuousAccountProcessingJob < ApplicationJob
  include ScheduledAccountBatching

  queue_as :sync

  DEFAULT_ACCOUNT_BATCH_SIZE = ENV.fetch("CONTINUOUS_PROCESSING_ENQUEUE_BATCH_SIZE", "25").to_i.clamp(5, 120)
  CONTINUATION_WAIT_SECONDS = ENV.fetch("CONTINUOUS_PROCESSING_ENQUEUE_CONTINUATION_WAIT_SECONDS", "2").to_i.clamp(1, 60)

  def perform(opts = nil, **kwargs)
    params = normalize_scheduler_params(
      opts,
      kwargs,
      limit: 100,
      batch_size: DEFAULT_ACCOUNT_BATCH_SIZE,
      cursor_id: nil,
      remaining: nil
    )
    cap = params[:limit].to_i.clamp(1, 500)
    remaining = params[:remaining].present? ? params[:remaining].to_i : cap
    remaining = remaining.clamp(0, cap)
    return { enqueued: 0, limit: cap, remaining: 0 } if remaining <= 0

    batch = load_account_batch(
      scope: InstagramAccount.where(continuous_processing_enabled: true),
      cursor_id: params[:cursor_id],
      batch_size: [ params[:batch_size].to_i.clamp(1, 120), remaining ].min
    )

    enqueued = 0
    now = Time.current
    batch[:accounts].each do |account|
      next if account.cookies.blank?
      next if account.continuous_processing_retry_after_at.present? && account.continuous_processing_retry_after_at > now

      ProcessInstagramAccountContinuouslyJob.perform_later(
        instagram_account_id: account.id,
        trigger_source: "scheduler"
      )
      enqueued += 1
    rescue StandardError => e
      Ops::StructuredLogger.warn(
        event: "continuous_processing.enqueue_failed",
        payload: {
          account_id: account.id,
          error_class: e.class.name,
          error_message: e.message
        }
      )
    end

    scanned = batch[:accounts].length
    remaining_after_batch = [ remaining - scanned, 0 ].max
    continuation_job = nil
    if batch[:has_more] && remaining_after_batch.positive?
      continuation_job = schedule_account_batch_continuation!(
        wait_seconds: CONTINUATION_WAIT_SECONDS,
        payload: {
          limit: cap,
          batch_size: batch[:batch_size],
          cursor_id: batch[:next_cursor_id],
          remaining: remaining_after_batch
        }
      )
    end

    Ops::StructuredLogger.info(
      event: "continuous_processing.batch_enqueued",
      payload: {
        limit: cap,
        batch_size: batch[:batch_size],
        scanned_accounts: scanned,
        enqueued_count: enqueued,
        remaining_after_batch: remaining_after_batch,
        continuation_enqueued: continuation_job.present?,
        continuation_job_id: continuation_job&.job_id
      }
    )

    {
      enqueued: enqueued,
      limit: cap,
      batch_size: batch[:batch_size],
      scanned_accounts: scanned,
      remaining_after_batch: remaining_after_batch,
      continuation_job_id: continuation_job&.job_id
    }
  end
end
