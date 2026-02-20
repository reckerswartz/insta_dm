class EnqueueStoryAutoRepliesForAllAccountsJob < ApplicationJob
  include ScheduledAccountBatching

  queue_as :story_downloads

  DEFAULT_ACCOUNT_BATCH_SIZE = ENV.fetch("STORY_AUTO_REPLY_ACCOUNT_BATCH_SIZE", "20").to_i.clamp(5, 120)
  CONTINUATION_WAIT_SECONDS = ENV.fetch("STORY_AUTO_REPLY_CONTINUATION_WAIT_SECONDS", "3").to_i.clamp(1, 90)

  def perform(opts = nil, **kwargs)
    params = normalize_scheduler_params(
      opts,
      kwargs,
      max_stories: 10,
      force_analyze_all: false,
      profile_limit: SyncProfileStoriesForAccountJob::STORY_BATCH_LIMIT,
      batch_size: DEFAULT_ACCOUNT_BATCH_SIZE,
      cursor_id: nil
    )
    max_stories_i = params[:max_stories].to_i.clamp(1, 10)
    force = ActiveModel::Type::Boolean.new.cast(params[:force_analyze_all])
    profile_limit = params[:profile_limit].to_i.clamp(1, SyncProfileStoriesForAccountJob::STORY_BATCH_LIMIT)
    batch = load_account_batch(
      scope: InstagramAccount.all,
      cursor_id: params[:cursor_id],
      batch_size: params[:batch_size]
    )

    enqueued = 0

    batch[:accounts].each do |account|
      next if account.cookies.blank?

      SyncProfileStoriesForAccountJob.perform_later(
        instagram_account_id: account.id,
        story_limit: profile_limit,
        stories_per_profile: max_stories_i,
        with_comments: true,
        require_auto_reply_tag: true,
        force_analyze_all: force
      )
      enqueued += 1
    rescue StandardError => e
      Ops::StructuredLogger.warn(
        event: "story_auto_reply.enqueue_failed",
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
          max_stories: max_stories_i,
          force_analyze_all: force,
          profile_limit: profile_limit,
          batch_size: batch[:batch_size],
          cursor_id: batch[:next_cursor_id]
        }
      )
    end

    Ops::StructuredLogger.info(
      event: "story_auto_reply.batch_enqueued",
      payload: {
        enqueued_accounts: enqueued,
        scanned_accounts: batch[:accounts].length,
        max_stories: max_stories_i,
        force_analyze_all: force,
        profile_limit: profile_limit,
        batch_size: batch[:batch_size],
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
