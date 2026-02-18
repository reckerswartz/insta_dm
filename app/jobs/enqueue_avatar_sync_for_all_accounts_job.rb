class EnqueueAvatarSyncForAllAccountsJob < ApplicationJob
  queue_as :avatars

  def perform(opts = nil, **kwargs)
    params = normalize_params(opts, kwargs, limit: 500)
    limit = params[:limit].to_i.clamp(1, 2000)

    InstagramAccount.find_each do |account|
      next if account.cookies.blank?

      DownloadMissingAvatarsJob.perform_later(instagram_account_id: account.id, limit: limit)
    rescue StandardError
      next
    end
  end

  private

  def normalize_params(opts, kwargs, defaults)
    from_opts = opts.is_a?(Hash) ? opts.symbolize_keys : {}
    defaults.merge(from_opts).merge(kwargs.symbolize_keys)
  end
end
