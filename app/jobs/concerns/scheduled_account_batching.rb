module ScheduledAccountBatching
  extend ActiveSupport::Concern

  MAX_ACCOUNT_BATCH_SIZE = 200
  MAX_CONTINUATION_WAIT_SECONDS = 300

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
end
