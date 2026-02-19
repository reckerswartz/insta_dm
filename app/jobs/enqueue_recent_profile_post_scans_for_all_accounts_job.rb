class EnqueueRecentProfilePostScansForAllAccountsJob < ApplicationJob
  queue_as :post_downloads

  # Accept a single hash (e.g. from Sidekiq cron/schedule) or keyword args from perform_later(...)
  def perform(opts = nil, **kwargs)
    params = normalize_params(opts, kwargs, limit_per_account: 8, posts_limit: 3, comments_limit: 8)
    limit_per_account = params[:limit_per_account].to_i.clamp(1, 30)
    posts_limit_i = params[:posts_limit].to_i.clamp(1, 3)
    comments_limit_i = params[:comments_limit].to_i.clamp(1, 20)

    enqueued_accounts = 0

    InstagramAccount.find_each do |account|
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

    Ops::StructuredLogger.info(
      event: "profile_scan.all_accounts_batch_enqueued",
      payload: {
        accounts_enqueued: enqueued_accounts,
        limit_per_account: limit_per_account,
        posts_limit: posts_limit_i,
        comments_limit: comments_limit_i
      }
    )
  end

  private

  def normalize_params(opts, kwargs, defaults)
    from_opts = opts.is_a?(Hash) ? opts.symbolize_keys : {}
    defaults.merge(from_opts).merge(kwargs.symbolize_keys)
  end
end
