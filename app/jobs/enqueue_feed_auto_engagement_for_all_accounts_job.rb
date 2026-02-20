class EnqueueFeedAutoEngagementForAllAccountsJob < ApplicationJob
  include ScheduledAccountBatching

  queue_as :sync

  DEFAULT_ACCOUNT_BATCH_SIZE = ENV.fetch("FEED_AUTO_ENGAGEMENT_ACCOUNT_BATCH_SIZE", "25").to_i.clamp(5, 120)
  CONTINUATION_WAIT_SECONDS = ENV.fetch("FEED_AUTO_ENGAGEMENT_CONTINUATION_WAIT_SECONDS", "3").to_i.clamp(1, 90)

  def perform(opts = nil, **kwargs)
    params = normalize_scheduler_params(
      opts,
      kwargs,
      max_posts: 3,
      include_story: true,
      story_hold_seconds: 18,
      batch_size: DEFAULT_ACCOUNT_BATCH_SIZE,
      cursor_id: nil
    )
    max_posts_i = params[:max_posts].to_i.clamp(1, 10)
    include_story_bool = ActiveModel::Type::Boolean.new.cast(params[:include_story])
    hold_seconds_i = params[:story_hold_seconds].to_i.clamp(8, 40)
    batch = load_account_batch(
      scope: InstagramAccount.all,
      cursor_id: params[:cursor_id],
      batch_size: params[:batch_size]
    )

    enqueued = 0

    batch[:accounts].each do |account|
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

    continuation_job = nil
    if batch[:has_more]
      continuation_job = schedule_account_batch_continuation!(
        wait_seconds: CONTINUATION_WAIT_SECONDS,
        payload: {
          max_posts: max_posts_i,
          include_story: include_story_bool,
          story_hold_seconds: hold_seconds_i,
          batch_size: batch[:batch_size],
          cursor_id: batch[:next_cursor_id]
        }
      )
    end

    Ops::StructuredLogger.info(
      event: "feed_auto_engagement.batch_enqueued",
      payload: {
        enqueued_accounts: enqueued,
        max_posts: max_posts_i,
        include_story: include_story_bool,
        story_hold_seconds: hold_seconds_i,
        batch_size: batch[:batch_size],
        scanned_accounts: batch[:accounts].length,
        continuation_enqueued: continuation_job.present?,
        continuation_job_id: continuation_job&.job_id
      }
    )

    {
      enqueued_accounts: enqueued,
      scanned_accounts: batch[:accounts].length,
      continuation_job_id: continuation_job&.job_id
    }
  end
end
