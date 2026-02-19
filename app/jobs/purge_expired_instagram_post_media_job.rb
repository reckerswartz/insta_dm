class PurgeExpiredInstagramPostMediaJob < ApplicationJob
  queue_as :post_downloads

  def perform(opts = nil, **kwargs)
    params = normalize_params(opts, kwargs, limit: 200)
    now = Time.current
    scope = InstagramPost.where("purge_at IS NOT NULL AND purge_at <= ?", now).order(purge_at: :asc).limit(params[:limit].to_i.clamp(1, 2000))

    scope.find_each do |post|
      begin
        post.media.purge if post.media.attached?
      rescue StandardError
        nil
      end
      post.update_columns(purge_at: nil) # avoid reprocessing
    end
  end

  private

  def normalize_params(opts, kwargs, defaults)
    from_opts = opts.is_a?(Hash) ? opts.symbolize_keys : {}
    defaults.merge(from_opts).merge(kwargs.symbolize_keys)
  end
end
