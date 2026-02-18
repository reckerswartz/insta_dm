class RetryFailedBackgroundJobsJob < ApplicationJob
  queue_as :sync

  def perform(opts = nil, **kwargs)
    params = normalize_params(opts, kwargs, limit: 20, max_attempts: 3, cooldown_minutes: 10)
    Jobs::FailureRetry.enqueue_automatic_retries!(
      limit: params[:limit],
      max_attempts: params[:max_attempts],
      cooldown: params[:cooldown_minutes].to_i.clamp(1, 120).minutes
    )
  end

  private

  def normalize_params(opts, kwargs, defaults)
    from_opts = opts.is_a?(Hash) ? opts.symbolize_keys : {}
    defaults.merge(from_opts).merge(kwargs.symbolize_keys)
  end
end
