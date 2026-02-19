module Pipeline
  class AccountProcessingCoordinator
    STORY_SYNC_INTERVAL = 90.minutes
    FEED_SYNC_INTERVAL = 2.hours
    PROFILE_SCAN_INTERVAL = 75.minutes
    FALLBACK_PROFILE_REFRESH_INTERVAL = 45.minutes

    def initialize(account:, trigger_source:, now: Time.current)
      @account = account
      @trigger_source = trigger_source.to_s.presence || "unspecified"
      @now = now
    end

    def run!
      stats = {
        trigger_source: @trigger_source,
        started_at: @now.iso8601(3),
        enqueued_jobs: [],
        skipped_jobs: []
      }

      health = Ops::LocalAiHealth.check
      stats[:local_ai_health] = health

      if due_for_story_sync?
        if health_ok?(health)
          enqueue_story_sync!(stats)
          @account.continuous_processing_next_story_sync_at = next_time(STORY_SYNC_INTERVAL)
        else
          stats[:skipped_jobs] << { job: "SyncHomeStoryCarouselJob", reason: "local_ai_unhealthy" }
        end
      end

      if due_for_feed_sync?
        if health_ok?(health)
          enqueue_feed_engagement!(stats)
          @account.continuous_processing_next_feed_sync_at = next_time(FEED_SYNC_INTERVAL)
        else
          stats[:skipped_jobs] << { job: "AutoEngageHomeFeedJob", reason: "local_ai_unhealthy" }
        end
      end

      if due_for_profile_scan?
        if health_ok?(health)
          enqueue_profile_scan!(stats)
          @account.continuous_processing_next_profile_scan_at = next_time(PROFILE_SCAN_INTERVAL)
        else
          enqueue_profile_refresh_fallback!(stats)
          @account.continuous_processing_next_profile_scan_at = next_time(FALLBACK_PROFILE_REFRESH_INTERVAL)
        end
      end

      enqueue_workspace_actions!(stats)

      @account.update!(
        continuous_processing_last_heartbeat_at: Time.current,
        continuous_processing_next_story_sync_at: @account.continuous_processing_next_story_sync_at,
        continuous_processing_next_feed_sync_at: @account.continuous_processing_next_feed_sync_at,
        continuous_processing_next_profile_scan_at: @account.continuous_processing_next_profile_scan_at
      )

      stats[:finished_at] = Time.current.iso8601(3)
      stats
    end

    private

    def due_for_story_sync?
      due?(@account.continuous_processing_next_story_sync_at)
    end

    def due_for_feed_sync?
      due?(@account.continuous_processing_next_feed_sync_at)
    end

    def due_for_profile_scan?
      due?(@account.continuous_processing_next_profile_scan_at)
    end

    def due?(timestamp)
      timestamp.blank? || timestamp <= @now
    end

    def health_ok?(health)
      ActiveModel::Type::Boolean.new.cast(health.is_a?(Hash) ? health[:ok] : false)
    end

    def enqueue_story_sync!(stats)
      job = SyncHomeStoryCarouselJob.perform_later(
        instagram_account_id: @account.id,
        story_limit: SyncHomeStoryCarouselJob::STORY_BATCH_LIMIT,
        auto_reply_only: false
      )

      stats[:enqueued_jobs] << {
        job: "SyncHomeStoryCarouselJob",
        active_job_id: job.job_id,
        queue: job.queue_name,
        story_limit: SyncHomeStoryCarouselJob::STORY_BATCH_LIMIT
      }

      Ops::StructuredLogger.info(
        event: "continuous_processing.story_sync_enqueued",
        payload: {
          account_id: @account.id,
          active_job_id: job.job_id,
          trigger_source: @trigger_source
        }
      )
    end

    def enqueue_feed_engagement!(stats)
      job = AutoEngageHomeFeedJob.perform_later(
        instagram_account_id: @account.id,
        max_posts: 2,
        include_story: false,
        story_hold_seconds: 18
      )

      stats[:enqueued_jobs] << {
        job: "AutoEngageHomeFeedJob",
        active_job_id: job.job_id,
        queue: job.queue_name,
        max_posts: 2
      }

      Ops::StructuredLogger.info(
        event: "continuous_processing.feed_engagement_enqueued",
        payload: {
          account_id: @account.id,
          active_job_id: job.job_id,
          trigger_source: @trigger_source
        }
      )
    end

    def enqueue_profile_scan!(stats)
      job = EnqueueRecentProfilePostScansForAccountJob.perform_later(
        instagram_account_id: @account.id,
        limit_per_account: 6,
        posts_limit: 3,
        comments_limit: 8
      )

      stats[:enqueued_jobs] << {
        job: "EnqueueRecentProfilePostScansForAccountJob",
        active_job_id: job.job_id,
        queue: job.queue_name,
        limit_per_account: 6,
        posts_limit: 3,
        comments_limit: 8
      }

      Ops::StructuredLogger.info(
        event: "continuous_processing.profile_scan_enqueued",
        payload: {
          account_id: @account.id,
          active_job_id: job.job_id,
          trigger_source: @trigger_source
        }
      )
    end

    def enqueue_profile_refresh_fallback!(stats)
      job = SyncNextProfilesForAccountJob.perform_later(
        instagram_account_id: @account.id,
        limit: 10
      )

      stats[:enqueued_jobs] << {
        job: "SyncNextProfilesForAccountJob",
        active_job_id: job.job_id,
        queue: job.queue_name,
        limit: 10,
        fallback_reason: "local_ai_unhealthy"
      }

      Ops::StructuredLogger.warn(
        event: "continuous_processing.profile_refresh_fallback_enqueued",
        payload: {
          account_id: @account.id,
          active_job_id: job.job_id,
          trigger_source: @trigger_source
        }
      )
    end

    def enqueue_workspace_actions!(stats)
      result = Workspace::ActionsTodoQueueService.new(
        account: @account,
        limit: 40,
        enqueue_processing: true
      ).fetch!
      queue_stats = result[:stats].is_a?(Hash) ? result[:stats] : {}

      stats[:enqueued_jobs] << {
        job: "Workspace::ActionsTodoQueueService",
        source: "continuous_processing",
        queued_now: queue_stats[:enqueued_now].to_i,
        ready_items: queue_stats[:ready_items].to_i,
        processing_items: queue_stats[:processing_items].to_i,
        total_items: queue_stats[:total_items].to_i
      }

      Ops::StructuredLogger.info(
        event: "continuous_processing.workspace_actions_refreshed",
        payload: {
          account_id: @account.id,
          trigger_source: @trigger_source,
          queued_now: queue_stats[:enqueued_now].to_i,
          ready_items: queue_stats[:ready_items].to_i,
          processing_items: queue_stats[:processing_items].to_i,
          total_items: queue_stats[:total_items].to_i
        }
      )
    rescue StandardError => e
      stats[:skipped_jobs] << {
        job: "Workspace::ActionsTodoQueueService",
        reason: "workspace_queue_refresh_failed",
        error_class: e.class.name
      }

      Ops::StructuredLogger.warn(
        event: "continuous_processing.workspace_actions_refresh_failed",
        payload: {
          account_id: @account.id,
          trigger_source: @trigger_source,
          error_class: e.class.name,
          error_message: e.message.to_s.byteslice(0, 280)
        }
      )
    end

    def next_time(interval)
      @now + jitter(interval)
    end

    def jitter(interval)
      seconds = interval.to_i
      jitter = (seconds * 0.12).to_i
      seconds + rand(0..jitter)
    end
  end
end
