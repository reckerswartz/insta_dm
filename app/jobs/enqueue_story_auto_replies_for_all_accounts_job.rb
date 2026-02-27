class EnqueueStoryAutoRepliesForAllAccountsJob < ApplicationJob
  include ScheduledAccountBatching

  queue_as :story_auto_reply_orchestration

  DEFAULT_ACCOUNT_BATCH_SIZE = ENV.fetch("STORY_AUTO_REPLY_ACCOUNT_BATCH_SIZE", "20").to_i.clamp(5, 120)
  CONTINUATION_WAIT_SECONDS = ENV.fetch("STORY_AUTO_REPLY_CONTINUATION_WAIT_SECONDS", "3").to_i.clamp(1, 90)
  ACCOUNT_ENQUEUE_STAGGER_SECONDS = ENV.fetch("STORY_AUTO_REPLY_ACCOUNT_ENQUEUE_STAGGER_SECONDS", "5").to_i.clamp(0, 120)
  ACCOUNT_ENQUEUE_JITTER_SECONDS = ENV.fetch("STORY_AUTO_REPLY_ACCOUNT_ENQUEUE_JITTER_SECONDS", "3").to_i.clamp(0, 30)

  def perform(opts = nil, **kwargs)
    params = normalize_scheduler_params(
      opts,
      kwargs,
      max_stories: 10,
      force_analyze_all: false,
      profile_limit: SyncProfileStoriesForAccountJob::STORY_BATCH_LIMIT,
      auto_reply: true,
      require_auto_reply_tag: true,
      batch_size: DEFAULT_ACCOUNT_BATCH_SIZE,
      cursor_id: nil
    )
    max_stories_i = params[:max_stories].to_i.clamp(1, 10)
    force = ActiveModel::Type::Boolean.new.cast(params[:force_analyze_all])
    profile_limit = params[:profile_limit].to_i.clamp(1, SyncProfileStoriesForAccountJob::STORY_BATCH_LIMIT)
    auto_reply = ActiveModel::Type::Boolean.new.cast(params[:auto_reply])
    require_auto_reply_tag = ActiveModel::Type::Boolean.new.cast(params[:require_auto_reply_tag])
    batch = load_account_batch(
      scope: InstagramAccount.all,
      cursor_id: params[:cursor_id],
      batch_size: params[:batch_size]
    )

    enqueued = 0
    scheduler_lease_skipped = 0
    backlog_skipped = 0

    batch[:accounts].each do |account|
      next if account.cookies.blank?
      gate_snapshot = Pipeline::SequentialProcessingGate.new(account: account).snapshot
      gate_counts = gate_snapshot[:blocking_counts].is_a?(Hash) ? gate_snapshot[:blocking_counts] : {}
      story_events_pending = gate_counts[:story_events_pending].to_i
      story_jobs_active = gate_counts[:story_jobs_active].to_i
      story_blocking_reasons = []
      story_blocking_reasons << "story_pipeline_pending" if story_events_pending.positive?
      story_blocking_reasons << "story_jobs_active" if story_jobs_active.positive?
      if story_blocking_reasons.any?
        backlog_skipped += 1
        Ops::StructuredLogger.info(
          event: "story_auto_reply.skipped_pending_backlog",
          payload: {
            account_id: account.id,
            blocking_reasons: story_blocking_reasons,
            blocking_counts: {
              story_events_pending: story_events_pending,
              story_jobs_active: story_jobs_active
            }
          }
        )
        next
      end

      scheduler_lease = AutonomousSchedulerLease.reserve!(account: account, source: self.class.name)
      unless scheduler_lease.reserved
        scheduler_lease_skipped += 1
        next
      end

      enqueue_account_job_with_delay!(
        job_class: SyncProfileStoriesForAccountJob,
        slot_index: enqueued,
        account_id: account.id,
        stagger_seconds: ACCOUNT_ENQUEUE_STAGGER_SECONDS,
        jitter_seconds: ACCOUNT_ENQUEUE_JITTER_SECONDS,
        args: {
          instagram_account_id: account.id,
          story_limit: profile_limit,
          stories_per_profile: max_stories_i,
          with_comments: auto_reply,
          require_auto_reply_tag: require_auto_reply_tag,
          force_analyze_all: force
        }
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
          auto_reply: auto_reply,
          require_auto_reply_tag: require_auto_reply_tag,
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
        scheduler_lease_skipped: scheduler_lease_skipped,
        backlog_skipped: backlog_skipped,
        max_stories: max_stories_i,
        force_analyze_all: force,
        profile_limit: profile_limit,
        auto_reply: auto_reply,
        require_auto_reply_tag: require_auto_reply_tag,
        batch_size: batch[:batch_size],
        continuation_enqueued: continuation_job.present?,
        continuation_job_id: continuation_job&.job_id
      }
    )

    {
      enqueued_accounts: enqueued,
      scanned_accounts: batch[:accounts].length,
      scheduler_lease_skipped: scheduler_lease_skipped,
      backlog_skipped: backlog_skipped,
      auto_reply: auto_reply,
      require_auto_reply_tag: require_auto_reply_tag,
      continuation_job_id: continuation_job&.job_id
    }
  end
end
