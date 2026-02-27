module Pipeline
  class SequentialProcessingGate
    STORY_ACTIVE_JOB_CLASSES = %w[
      SyncHomeStoryCarouselJob
      SyncProfileStoriesForAccountJob
      SyncInstagramProfileStoriesJob
      StoryProcessingJob
      AnalyzeInstagramStoryEventJob
      StoryCommentPipelineJob
      StoryCommentStepJob
      ProcessStoryCommentFaceJob
      ProcessStoryCommentMetadataJob
      FinalizeStoryCommentPipelineJob
      GenerateStoryCommentFromPipelineJob
      GenerateLlmCommentJob
      ValidateStoryReplyEligibilityJob
      SendStoryReplyJob
      SendStoryReplyEngagementJob
      GenerateStoryPreviewImageJob
    ].freeze

    FEED_ACTIVE_JOB_CLASSES = %w[
      CaptureHomeFeedJob
      AutoEngageHomeFeedJob
      EnqueueRecentProfilePostScansForAccountJob
      SyncRecentProfilePostsForProfileJob
      CaptureInstagramProfilePostsJob
      AnalyzeCapturedInstagramProfilePostsJob
      DownloadInstagramProfilePostMediaJob
    ].freeze

    WORKSPACE_PENDING_STATUSES = %w[
      queued
      running
      waiting_media_download
      waiting_post_analysis
      waiting_comment_generation
      waiting_build_history
      waiting_profile_analysis
    ].freeze

    POST_PENDING_STATUSES = %w[pending running].freeze
    STORY_PENDING_STATUSES = %w[queued running].freeze

    def initialize(account:, now: Time.current)
      @account = account
      @now = now
    end

    def blocked?
      ActiveModel::Type::Boolean.new.cast(snapshot[:blocked])
    end

    def snapshot
      @snapshot ||= begin
        counts = {
          story_events_pending: pending_story_events_count,
          posts_pending: pending_posts_count,
          workspace_items_pending: pending_workspace_items_count,
          story_jobs_active: active_story_jobs_count,
          feed_jobs_active: active_feed_jobs_count,
          workspace_jobs_active: active_workspace_jobs_count
        }

        reasons = []
        reasons << "story_pipeline_pending" if counts[:story_events_pending].positive?
        reasons << "post_pipeline_pending" if counts[:posts_pending].positive?
        reasons << "workspace_items_pending" if counts[:workspace_items_pending].positive?
        reasons << "story_jobs_active" if counts[:story_jobs_active].positive?
        reasons << "feed_jobs_active" if counts[:feed_jobs_active].positive?
        reasons << "workspace_jobs_active" if counts[:workspace_jobs_active].positive?

        {
          blocked: reasons.any?,
          blocking_reasons: reasons,
          blocking_counts: counts,
          checked_at: @now.iso8601(3)
        }
      end
    rescue StandardError => e
      {
        blocked: false,
        blocking_reasons: [],
        blocking_counts: {},
        checked_at: @now.iso8601(3),
        error_class: e.class.name
      }
    end

    private

    def pending_story_events_count
      InstagramProfileEvent
        .joins(:instagram_profile)
        .where(instagram_profiles: { instagram_account_id: @account.id })
        .where(kind: InstagramProfileEvent::STORY_ARCHIVE_EVENT_KINDS)
        .where(
          "llm_comment_status IN (?) OR llm_blocking_step IS NOT NULL OR llm_pending_reason_code IS NOT NULL",
          STORY_PENDING_STATUSES
        )
        .count
    end

    def pending_posts_count
      @account.instagram_profile_posts
        .where(
          "ai_status IN (?) OR ai_blocking_step IS NOT NULL OR ai_pending_reason_code IS NOT NULL",
          POST_PENDING_STATUSES
        )
        .count
    end

    def pending_workspace_items_count
      @account.instagram_profile_posts
        .where("COALESCE(metadata -> 'workspace_actions' ->> 'status', '') IN (?)", WORKSPACE_PENDING_STATUSES)
        .count
    end

    def active_story_jobs_count
      active_job_scope.where(job_class: STORY_ACTIVE_JOB_CLASSES).count
    end

    def active_feed_jobs_count
      active_job_scope.where(job_class: FEED_ACTIVE_JOB_CLASSES).count
    end

    def active_workspace_jobs_count
      scope = active_job_scope
      scope.where(job_class: "WorkspaceProcessActionsTodoPostJob")
        .or(scope.where(queue_name: "workspace_actions_queue"))
        .count
    end

    def active_job_scope
      return BackgroundJobLifecycle.none unless lifecycle_table_available?

      BackgroundJobLifecycle.active.where(instagram_account_id: @account.id)
    end

    def lifecycle_table_available?
      BackgroundJobLifecycle.table_exists?
    rescue StandardError
      false
    end
  end
end
