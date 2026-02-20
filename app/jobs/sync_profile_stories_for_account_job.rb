class SyncProfileStoriesForAccountJob < ApplicationJob
  queue_as :story_downloads

  STORY_BATCH_LIMIT = 10
  STORIES_PER_PROFILE = SyncInstagramProfileStoriesJob::MAX_STORIES

  def perform(
    instagram_account_id:,
    story_limit: STORY_BATCH_LIMIT,
    stories_per_profile: STORIES_PER_PROFILE,
    with_comments: false,
    require_auto_reply_tag: false,
    force_analyze_all: false
  )
    account = InstagramAccount.find(instagram_account_id)
    limit = story_limit.to_i.clamp(1, STORY_BATCH_LIMIT)
    stories_per_profile_i = stories_per_profile.to_i.clamp(1, SyncInstagramProfileStoriesJob::MAX_STORIES)
    auto_reply = ActiveModel::Type::Boolean.new.cast(with_comments)
    require_tag = ActiveModel::Type::Boolean.new.cast(require_auto_reply_tag)
    force_analyze = ActiveModel::Type::Boolean.new.cast(force_analyze_all)

    scope = account.instagram_profiles
      .order(Arel.sql("COALESCE(last_story_seen_at, '1970-01-01') ASC, COALESCE(last_active_at, '1970-01-01') DESC, username ASC"))
    if require_tag
      scope = scope.joins(:profile_tags).where(profile_tags: { name: [ "automatic_reply", "automatic reply", "auto_reply", "auto reply" ] }).distinct
    end

    profiles = scope.limit(limit)

    profiles.each do |profile|
      action = auto_reply ? "auto_story_reply" : "sync_stories"
      log = profile.instagram_profile_action_logs.create!(
        instagram_account: account,
        action: action,
        status: "queued",
        trigger_source: auto_reply ? "account_sync_stories_with_comments" : "account_sync_profile_stories",
        occurred_at: Time.current,
        metadata: {
          requested_by: self.class.name,
          story_limit: limit,
          max_stories_per_profile: stories_per_profile_i,
          auto_reply: auto_reply,
          require_auto_reply_tag: require_tag,
          force_analyze_all: force_analyze
        }
      )

      job = SyncInstagramProfileStoriesJob.perform_later(
        instagram_account_id: account.id,
        instagram_profile_id: profile.id,
        profile_action_log_id: log.id,
        max_stories: stories_per_profile_i,
        force_analyze_all: force_analyze,
        auto_reply: auto_reply,
        require_auto_reply_tag: require_tag
      )
      log.update!(active_job_id: job.job_id, queue_name: job.queue_name)
    rescue StandardError => e
      Ops::StructuredLogger.warn(
        event: "sync_profile_stories.profile_enqueue_failed",
        payload: {
          account_id: account.id,
          profile_id: profile.id,
          error_class: e.class.name,
          error_message: e.message
        }
      )
      next
    end

    label = auto_reply ? "story sync with auto-reply" : "story sync"
    Turbo::StreamsChannel.broadcast_append_to(
      account,
      target: "notifications",
      partial: "shared/notification",
      locals: { kind: "notice", message: "Queued #{label} for #{profiles.size} stories (max #{STORY_BATCH_LIMIT})." }
    )
  end
end
