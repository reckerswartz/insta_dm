class EnqueueStoryAutoRepliesForAllAccountsJob < ApplicationJob
  queue_as :profiles

  def perform(max_stories: 10, force_analyze_all: false)
    max_stories_i = max_stories.to_i.clamp(1, 10)
    force = ActiveModel::Type::Boolean.new.cast(force_analyze_all)

    enqueued = 0

    InstagramAccount.find_each do |account|
      next if account.cookies.blank?

      scope = account.instagram_profiles.joins(:profile_tags).where(profile_tags: { name: [ "automatic_reply", "automatic reply" ] }).distinct
      scope.find_each do |profile|
        log = profile.instagram_profile_action_logs.create!(
          instagram_account: account,
          action: "auto_story_reply",
          status: "queued",
          trigger_source: "recurring_job",
          occurred_at: Time.current,
          metadata: { requested_by: self.class.name, max_stories: max_stories_i, force_analyze_all: force }
        )

        job = SyncInstagramProfileStoriesJob.perform_later(
          instagram_account_id: account.id,
          instagram_profile_id: profile.id,
          profile_action_log_id: log.id,
          max_stories: max_stories_i,
          force_analyze_all: force,
          auto_reply: true,
          require_auto_reply_tag: true
        )

        log.update!(active_job_id: job.job_id, queue_name: job.queue_name)
        enqueued += 1
      rescue StandardError
        next
      end
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

    Ops::StructuredLogger.info(
      event: "story_auto_reply.batch_enqueued",
      payload: {
        enqueued_profiles: enqueued,
        max_stories: max_stories_i,
        force_analyze_all: force
      }
    )
  end
end
