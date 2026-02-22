require_dependency "scheduled_account_batching"

class EnqueueContinuousAccountProcessingJob < ApplicationJob
  include ScheduledAccountBatching

  queue_as :sync

  DEFAULT_ACCOUNT_BATCH_SIZE = ENV.fetch("CONTINUOUS_PROCESSING_ENQUEUE_BATCH_SIZE", "25").to_i.clamp(5, 120)
  CONTINUATION_WAIT_SECONDS = ENV.fetch("CONTINUOUS_PROCESSING_ENQUEUE_CONTINUATION_WAIT_SECONDS", "2").to_i.clamp(1, 60)
  SCHEDULER_CURSOR_CACHE_KEY = "continuous_processing:enqueue_cursor:v1".freeze
  ACCOUNT_ENQUEUE_STAGGER_SECONDS = ENV.fetch("CONTINUOUS_PROCESSING_ACCOUNT_ENQUEUE_STAGGER_SECONDS", "4").to_i.clamp(0, 120)
  ACCOUNT_ENQUEUE_JITTER_SECONDS = ENV.fetch("CONTINUOUS_PROCESSING_ACCOUNT_ENQUEUE_JITTER_SECONDS", "2").to_i.clamp(0, 30)

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

    explicit_cursor_supplied = params[:cursor_id].to_i.positive?
    start_cursor_id = explicit_cursor_supplied ? params[:cursor_id] : persisted_scheduler_cursor_id

    batch = load_account_batch(
      scope: InstagramAccount.where(continuous_processing_enabled: true),
      cursor_id: start_cursor_id,
      batch_size: [ params[:batch_size].to_i.clamp(1, 120), remaining ].min
    )

    enqueued = 0
    scheduler_lease_skipped = 0
    now = Time.current
    batch[:accounts].each do |account|
      next if account.cookies.blank?
      next if account.continuous_processing_retry_after_at.present? && account.continuous_processing_retry_after_at > now

      scheduler_lease = AutonomousSchedulerLease.reserve!(account: account, source: self.class.name)
      unless scheduler_lease.reserved
        scheduler_lease_skipped += 1
        Ops::StructuredLogger.info(
          event: "continuous_processing.skipped_scheduler_lease",
          payload: {
            account_id: account.id,
            blocked_by: scheduler_lease.blocked_by,
            remaining_seconds: scheduler_lease.remaining_seconds.to_i
          }
        )
        next
      end

      enqueue_account_job_with_delay!(
        job_class: ProcessInstagramAccountContinuouslyJob,
        slot_index: enqueued,
        account_id: account.id,
        stagger_seconds: ACCOUNT_ENQUEUE_STAGGER_SECONDS,
        jitter_seconds: ACCOUNT_ENQUEUE_JITTER_SECONDS,
        args: {
          instagram_account_id: account.id,
          trigger_source: "scheduler"
        }
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
    persisted_cursor_id = persist_scheduler_cursor!(next_cursor_id: batch[:next_cursor_id], has_more: batch[:has_more])

    Ops::StructuredLogger.info(
      event: "continuous_processing.batch_enqueued",
      payload: {
        limit: cap,
        batch_size: batch[:batch_size],
        start_cursor_id: start_cursor_id,
        scanned_accounts: scanned,
        enqueued_count: enqueued,
        scheduler_lease_skipped: scheduler_lease_skipped,
        remaining_after_batch: remaining_after_batch,
        persisted_cursor_id: persisted_cursor_id,
        continuation_enqueued: continuation_job.present?,
        continuation_job_id: continuation_job&.job_id
      }
    )

    {
      enqueued: enqueued,
      limit: cap,
      batch_size: batch[:batch_size],
      start_cursor_id: start_cursor_id,
      scanned_accounts: scanned,
      scheduler_lease_skipped: scheduler_lease_skipped,
      remaining_after_batch: remaining_after_batch,
      persisted_cursor_id: persisted_cursor_id,
      continuation_job_id: continuation_job&.job_id
    }
  end

  private

  def persisted_scheduler_cursor_id
    value = scheduler_cursor_store.read(scheduler_cursor_cache_key).to_i
    value.positive? ? value : nil
  rescue StandardError
    nil
  end

  def persist_scheduler_cursor!(next_cursor_id:, has_more:)
    key = scheduler_cursor_cache_key
    if has_more && next_cursor_id.to_i.positive?
      cursor_id = next_cursor_id.to_i
      scheduler_cursor_store.write(key, cursor_id, expires_in: 30.days)
      cursor_id
    else
      scheduler_cursor_store.delete(key)
      nil
    end
  rescue StandardError
    nil
  end

  def scheduler_cursor_cache_key
    "#{SCHEDULER_CURSOR_CACHE_KEY}:#{Rails.env}"
  end

  def scheduler_cursor_store
    return Rails.cache unless Rails.cache.is_a?(ActiveSupport::Cache::NullStore)

    self.class.instance_variable_get(:@scheduler_cursor_store) ||
      self.class.instance_variable_set(
        :@scheduler_cursor_store,
        ActiveSupport::Cache::MemoryStore.new(expires_in: 30.days)
      )
  rescue StandardError
    Rails.cache
  end
end
