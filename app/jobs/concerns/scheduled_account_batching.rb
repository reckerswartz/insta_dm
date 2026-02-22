module ScheduledAccountBatching
  extend ActiveSupport::Concern

  MAX_ACCOUNT_BATCH_SIZE = 200
  MAX_CONTINUATION_WAIT_SECONDS = 300
  MAX_ACCOUNT_ENQUEUE_DELAY_SECONDS = 30.minutes.to_i
  MAX_ACCOUNT_ENQUEUE_STAGGER_SECONDS = 120
  MAX_ACCOUNT_ENQUEUE_JITTER_SECONDS = 30
  DEFAULT_ACCOUNT_ENQUEUE_STAGGER_SECONDS = ENV.fetch("SCHEDULED_ACCOUNT_ENQUEUE_STAGGER_SECONDS", "4").to_i.clamp(0, MAX_ACCOUNT_ENQUEUE_STAGGER_SECONDS)
  DEFAULT_ACCOUNT_ENQUEUE_JITTER_SECONDS = ENV.fetch("SCHEDULED_ACCOUNT_ENQUEUE_JITTER_SECONDS", "2").to_i.clamp(0, MAX_ACCOUNT_ENQUEUE_JITTER_SECONDS)

  private

  def normalize_scheduler_params(opts, kwargs, defaults)
    from_opts = opts.is_a?(Hash) ? opts.symbolize_keys : {}
    defaults.merge(from_opts).merge(kwargs.symbolize_keys)
  end

  def load_account_batch(scope:, cursor_id:, batch_size:)
    table = InstagramAccount.arel_table
    capped_batch_size = batch_size.to_i.clamp(1, MAX_ACCOUNT_BATCH_SIZE)

    ordered_scope = scope.reorder(table[:id].asc)
    if cursor_id.to_i.positive?
      ordered_scope = ordered_scope.where(table[:id].gt(cursor_id.to_i))
    end

    accounts = ordered_scope.limit(capped_batch_size).to_a
    next_cursor_id = accounts.last&.id
    has_more = next_cursor_id.present? && scope.where(table[:id].gt(next_cursor_id.to_i)).exists?

    {
      accounts: accounts,
      batch_size: capped_batch_size,
      next_cursor_id: next_cursor_id,
      has_more: has_more
    }
  end

  def schedule_account_batch_continuation!(wait_seconds:, payload:)
    args = payload.is_a?(Hash) ? payload.compact : {}
    return nil if args.empty?

    capped_wait = wait_seconds.to_i.clamp(0, MAX_CONTINUATION_WAIT_SECONDS)
    if capped_wait.positive?
      self.class.set(wait: capped_wait.seconds).perform_later(**args)
    else
      self.class.perform_later(**args)
    end
  end

  def enqueue_account_job_with_delay!(
    job_class:,
    slot_index:,
    account_id:,
    args:,
    stagger_seconds: DEFAULT_ACCOUNT_ENQUEUE_STAGGER_SECONDS,
    jitter_seconds: DEFAULT_ACCOUNT_ENQUEUE_JITTER_SECONDS
  )
    payload = args.is_a?(Hash) ? args.compact : {}
    return nil if payload.empty?

    wait_seconds = account_enqueue_wait_seconds(
      slot_index: slot_index,
      account_id: account_id,
      stagger_seconds: stagger_seconds,
      jitter_seconds: jitter_seconds
    )

    if wait_seconds.positive?
      job_class.set(wait: wait_seconds.seconds).perform_later(**payload)
    else
      job_class.perform_later(**payload)
    end
  end

  def account_enqueue_wait_seconds(slot_index:, account_id:, stagger_seconds:, jitter_seconds:)
    slot = slot_index.to_i
    return 0 if slot <= 0

    stagger = stagger_seconds.to_i.clamp(0, MAX_ACCOUNT_ENQUEUE_STAGGER_SECONDS)
    jitter_max = jitter_seconds.to_i.clamp(0, MAX_ACCOUNT_ENQUEUE_JITTER_SECONDS)
    jitter = jitter_max.positive? ? account_id.to_i.abs % (jitter_max + 1) : 0

    (slot * stagger + jitter).clamp(0, MAX_ACCOUNT_ENQUEUE_DELAY_SECONDS)
  end
end
