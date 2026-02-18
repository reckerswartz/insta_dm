class EnqueueFeedAutoEngagementForAllAccountsJob < ApplicationJob
  queue_as :sync

  def perform(opts = nil, **kwargs)
    params = normalize_params(opts, kwargs, max_posts: 3, include_story: true, story_hold_seconds: 18)
    max_posts_i = params[:max_posts].to_i.clamp(1, 10)
    include_story_bool = ActiveModel::Type::Boolean.new.cast(params[:include_story])
    hold_seconds_i = params[:story_hold_seconds].to_i.clamp(8, 40)

    enqueued = 0

    InstagramAccount.find_each do |account|
      next if account.cookies.blank?

      AutoEngageHomeFeedJob.perform_later(
        instagram_account_id: account.id,
        max_posts: max_posts_i,
        include_story: include_story_bool,
        story_hold_seconds: hold_seconds_i
      )
      enqueued += 1
    rescue StandardError => e
      Ops::StructuredLogger.warn(
        event: "feed_auto_engagement.enqueue_failed",
        payload: {
          account_id: account.id,
          error_class: e.class.name,
          error_message: e.message
        }
      )
      next
    end

    Ops::StructuredLogger.info(
      event: "feed_auto_engagement.batch_enqueued",
      payload: {
        enqueued_accounts: enqueued,
        max_posts: max_posts_i,
        include_story: include_story_bool,
        story_hold_seconds: hold_seconds_i
      }
    )
  end

  private

  def normalize_params(opts, kwargs, defaults)
    from_opts = opts.is_a?(Hash) ? opts.symbolize_keys : {}
    defaults.merge(from_opts).merge(kwargs.symbolize_keys)
  end
end
