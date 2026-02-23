module Ops
  class Metrics
    API_USAGE_WINDOW = 24.hours

    def self.system
      usage_scope = AiApiCall.where(occurred_at: API_USAGE_WINDOW.ago..Time.current)

      {
        queue: queue_counts,
        queue_estimates: Ops::QueueProcessingEstimator.snapshot,
        job_execution_metrics_24h: Ops::JobExecutionMetricsSnapshot.snapshot(window_hours: 24, queue_limit: 8),
        service_output_audits_24h: Ops::ServiceOutputAuditSnapshot.snapshot(window_hours: 24, service_limit: 10, key_limit: 15),
        pipeline_pending: Ops::PipelinePendingSnapshot.snapshot,
        ai_service_queues: Ops::AiServiceQueueMetrics.snapshot,
        app: {
          accounts: InstagramAccount.count,
          continuous_processing_enabled_accounts: InstagramAccount.where(continuous_processing_enabled: true).count,
          continuous_processing_running_accounts: InstagramAccount.where(continuous_processing_state: "running").count,
          continuous_processing_backoff_accounts: InstagramAccount.where("continuous_processing_retry_after_at > ?", Time.current).count,
          profiles: InstagramProfile.count,
          messages: InstagramMessage.count,
          profile_events: InstagramProfileEvent.count,
          ai_analyses: AiAnalysis.count,
          ai_api_calls: AiApiCall.count,
          posts: InstagramPost.count,
          sync_runs: SyncRun.count,
          failures_24h: BackgroundJobFailure.where("occurred_at >= ?", 24.hours.ago).count,
          visual_analysis_failures_24h: BackgroundJobFailure.where(job_class: "ProcessPostVisualAnalysisJob")
            .where("occurred_at >= ?", 24.hours.ago).count,
          auth_failures_24h: BackgroundJobFailure.where(failure_kind: "authentication").where("occurred_at >= ?", 24.hours.ago).count,
          active_issues: AppIssue.where.not(status: "resolved").count,
          storage_ingestions_24h: ActiveStorageIngestion.where("created_at >= ?", 24.hours.ago).count,
          continuous_processing_runs_24h: SyncRun.where(kind: "continuous_processing").where("created_at >= ?", 24.hours.ago).count
        },
        api_usage_24h: api_usage_summary(scope: usage_scope),
        visual_failures_24h: visual_failure_summary(scope: BackgroundJobFailure.where(job_class: "ProcessPostVisualAnalysisJob")
          .where("occurred_at >= ?", 24.hours.ago))
      }
    end

    def self.for_account(account)
      usage_scope = AiApiCall.where(instagram_account_id: account.id, occurred_at: API_USAGE_WINDOW.ago..Time.current)

      {
        app: {
          profiles: account.instagram_profiles.count,
          mutuals: account.instagram_profiles.where(following: true, follows_you: true).count,
          following: account.instagram_profiles.where(following: true).count,
          followers: account.instagram_profiles.where(follows_you: true).count,
          messages: account.instagram_messages.count,
          profile_events: InstagramProfileEvent.joins(:instagram_profile).where(instagram_profiles: { instagram_account_id: account.id }).count,
          ai_analyses: account.ai_analyses.count,
          ai_api_calls: account.ai_api_calls.count,
          posts: account.instagram_posts.count,
          sync_runs: account.sync_runs.count,
          failures_24h: BackgroundJobFailure.where(instagram_account_id: account.id)
            .where("occurred_at >= ?", 24.hours.ago).count,
          visual_analysis_failures_24h: BackgroundJobFailure.where(instagram_account_id: account.id, job_class: "ProcessPostVisualAnalysisJob")
            .where("occurred_at >= ?", 24.hours.ago).count,
          auth_failures_24h: BackgroundJobFailure.where(instagram_account_id: account.id, failure_kind: "authentication")
            .where("occurred_at >= ?", 24.hours.ago).count,
          active_issues: account.app_issues.where.not(status: "resolved").count,
          storage_ingestions_24h: account.active_storage_ingestions.where("created_at >= ?", 24.hours.ago).count,
          continuous_processing_state: account.continuous_processing_state,
          continuous_processing_failure_count: account.continuous_processing_failure_count.to_i,
          continuous_processing_backoff_active: account.continuous_processing_backoff_active?,
          continuous_processing_runs_24h: account.sync_runs.where(kind: "continuous_processing").where("created_at >= ?", 24.hours.ago).count
        },
        sync_runs_by_status: account.sync_runs.group(:status).count,
        analyses_by_status: account.ai_analyses.group(:status).count,
        api_usage_24h: api_usage_summary(scope: usage_scope),
        ai_service_queues: Ops::AiServiceQueueMetrics.snapshot(account_id: account.id),
        queue_estimates: Ops::QueueProcessingEstimator.snapshot,
        job_execution_metrics_24h: Ops::JobExecutionMetricsSnapshot.snapshot(window_hours: 24, queue_limit: 8, account_id: account.id),
        service_output_audits_24h: Ops::ServiceOutputAuditSnapshot.snapshot(window_hours: 24, service_limit: 10, key_limit: 15, account_id: account.id),
        pipeline_pending: Ops::PipelinePendingSnapshot.snapshot(account_id: account.id),
        visual_failures_24h: visual_failure_summary(scope: BackgroundJobFailure.where(instagram_account_id: account.id, job_class: "ProcessPostVisualAnalysisJob")
          .where("occurred_at >= ?", 24.hours.ago)),
        queue: queue_counts
      }
    end

    def self.queue_counts
      sidekiq_backend? ? sidekiq_counts : solid_queue_counts
    end

    def self.sidekiq_counts
      require "sidekiq/api"

      queues = Sidekiq::Queue.all
      queue_rows = queues.map { |queue| { name: queue.name, size: queue.size } }

      {
        backend: "sidekiq",
        enqueued: queue_rows.sum { |row| row[:size].to_i },
        scheduled: Sidekiq::ScheduledSet.new.size,
        retries: Sidekiq::RetrySet.new.size,
        dead: Sidekiq::DeadSet.new.size,
        processes: Sidekiq::ProcessSet.new.size,
        queues: queue_rows
      }
    rescue StandardError
      {
        backend: "sidekiq",
        enqueued: 0,
        scheduled: 0,
        retries: 0,
        dead: 0,
        processes: 0,
        queues: []
      }
    end

    def self.solid_queue_counts
      {
        backend: "solid_queue",
        ready: safe_count { SolidQueue::ReadyExecution.count },
        scheduled: safe_count { SolidQueue::ScheduledExecution.count },
        claimed: safe_count { SolidQueue::ClaimedExecution.count },
        blocked: safe_count { SolidQueue::BlockedExecution.count },
        failed: safe_count { SolidQueue::FailedExecution.count },
        processes: safe_count { SolidQueue::Process.count }
      }
    end

    def self.sidekiq_backend?
      Rails.application.config.active_job.queue_adapter.to_s == "sidekiq"
    rescue StandardError
      false
    end

    def self.safe_count
      yield
    rescue StandardError
      0
    end

    def self.api_usage_summary(scope:)
      by_category = scope.group(:category).count.transform_keys(&:to_s)
      by_provider = scope.group(:provider).count.transform_keys(&:to_s)
      by_status = scope.group(:status).count.transform_keys(&:to_s)
      by_operation =
        scope.group(:operation).count.transform_keys(&:to_s)
          .sort_by { |_operation, count| -count.to_i }
          .first(10)
          .to_h

      {
        total_calls: scope.count,
        failed_calls: by_status["failed"].to_i,
        image_analysis_calls: by_category["image_analysis"].to_i,
        image_analysis_failures: scope.where(category: "image_analysis", status: "failed").count,
        report_generation_calls: by_category["report_generation"].to_i,
        text_generation_calls: by_category["text_generation"].to_i,
        total_tokens: scope.sum(:total_tokens).to_i,
        avg_latency_ms: scope.where.not(latency_ms: nil).average(:latency_ms)&.round(1),
        by_category: by_category,
        by_provider: by_provider,
        by_status: by_status,
        top_operations: by_operation
      }
    end

    def self.visual_failure_summary(scope:)
      top_errors =
        scope.group(:error_class, :error_message)
          .count
          .sort_by { |_row, count| -count.to_i }
          .first(5)
          .map do |(error_class, error_message), count|
            {
              error_class: error_class.to_s,
              error_message: error_message.to_s.byteslice(0, 180),
              count: count.to_i
            }
          end

      {
        total_failures: scope.count,
        by_error: top_errors
      }
    rescue StandardError
      {
        total_failures: 0,
        by_error: []
      }
    end
  end
end
