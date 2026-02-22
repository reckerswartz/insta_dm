class JobHealthMonitor
  class << self
    def check_queue_health!
      health_report = {
        timestamp: Time.current,
        queues: {},
        summary: {
          total_pending: 0,
          total_failed_recent: 0,
          critical_issues: []
        }
      }

      # Check each queue
      queue_names = monitored_queue_names

      queue_names.each do |queue_name|
        queue_health = analyze_queue_health(queue_name)
        health_report[:queues][queue_name] = queue_health
        health_report[:summary][:total_pending] += queue_health[:pending_jobs]
        health_report[:summary][:total_failed_recent] += queue_health[:recent_failures]

        if queue_health[:health_score] < 50
          health_report[:summary][:critical_issues] << {
            queue: queue_name,
            issue: queue_health[:primary_issue],
            score: queue_health[:health_score]
          }
        end

        if queue_health[:stale_processing]
          Ops::StructuredLogger.warn(
            event: "job.queue_stale_processing",
            payload: {
              queue_name: queue_name,
              oldest_in_process_runtime_seconds: queue_health[:oldest_in_process_runtime_seconds],
              in_process_jobs: queue_health[:in_process_jobs],
              pending_jobs: queue_health[:pending_jobs]
            }
          )
        end
      end

      # Log health report
      Ops::StructuredLogger.info(
        event: "job.health_check",
        payload: health_report
      )

      # Alert on critical issues
      if health_report[:summary][:critical_issues].any?
        alert_critical_queue_issues(health_report[:summary][:critical_issues])
      end

      health_report
    end

    def cleanup_stale_jobs!
      cleanup_stats = {
        timestamp: Time.current,
        cleaned_jobs: 0,
        cleaned_failures: 0,
        errors: []
      }

      # Clean up old job failures
      cutoff_date = 30.days.ago
      cleaned_failures = BackgroundJobFailure
        .where("occurred_at < ?", cutoff_date)
        .delete_all

      cleanup_stats[:cleaned_failures] = cleaned_failures

      # Clean up orphaned job state in post metadata
      cleaned_jobs = cleanup_orphaned_job_metadata
      cleanup_stats[:cleaned_jobs] = cleaned_jobs

      Ops::StructuredLogger.info(
        event: "job.cleanup_completed",
        payload: cleanup_stats
      )

      cleanup_stats
    end

    def analyze_failure_patterns
      patterns = {
        timestamp: Time.current,
        top_errors: get_top_error_patterns,
        failing_jobs: get_failing_job_patterns,
        hourly_trends: get_hourly_failure_trends,
        recommendations: []
      }

      # Generate recommendations based on patterns
      patterns[:recommendations] = generate_recommendations(patterns)

      Ops::StructuredLogger.info(
        event: "job.failure_analysis",
        payload: patterns
      )

      patterns
    end

    private

    def analyze_queue_health(queue_name)
      recent_failures = BackgroundJobFailure
        .where(queue_name: queue_name)
        .where("occurred_at > ?", 24.hours.ago)
        .count

      # Get queue size from Sidekiq
      queue_size = get_queue_size(queue_name)
      queue_latency_seconds = get_queue_latency(queue_name)
      processing = get_processing_metrics(queue_name)

      # Calculate health score (0-100)
      health_score = calculate_health_score(
        queue_size,
        recent_failures,
        queue_latency_seconds: queue_latency_seconds,
        in_process_jobs: processing[:in_process_jobs],
        oldest_in_process_runtime_seconds: processing[:oldest_in_process_runtime_seconds]
      )

      {
        queue_name: queue_name,
        pending_jobs: queue_size,
        recent_failures: recent_failures,
        queue_latency_seconds: queue_latency_seconds,
        in_process_jobs: processing[:in_process_jobs],
        oldest_in_process_runtime_seconds: processing[:oldest_in_process_runtime_seconds],
        stale_processing: processing[:stale_processing],
        health_score: health_score,
        primary_issue: determine_primary_issue(
          queue_size,
          recent_failures,
          queue_latency_seconds: queue_latency_seconds,
          in_process_jobs: processing[:in_process_jobs],
          oldest_in_process_runtime_seconds: processing[:oldest_in_process_runtime_seconds]
        ),
        status: health_status_label(health_score)
      }
    end

    def monitored_queue_names
      non_ai_queues = %w[
        frame_generation story_auto_reply_orchestration profile_story_orchestration home_story_orchestration
        home_story_sync story_processing story_preview_generation story_replies
        profiles profile_reevaluation engagements sync story_validation avatars avatar_orchestration
        post_downloads captured_posts messages workspace_actions_queue
      ]
      ai_queues = Ops::AiServiceQueueRegistry.ai_queue_names

      (ai_queues + non_ai_queues).map(&:to_s).reject(&:blank?).uniq
    rescue StandardError
      non_ai_queues
    end

    def get_queue_size(queue_name)
      begin
        Sidekiq::Queue.new(queue_name).size
      rescue StandardError => e
        Rails.logger.warn("[JobHealthMonitor] Failed to get queue size for #{queue_name}: #{e.message}")
        0
      end
    end

    def get_queue_latency(queue_name)
      begin
        Sidekiq::Queue.new(queue_name).latency.to_f.round(2)
      rescue StandardError => e
        Rails.logger.warn("[JobHealthMonitor] Failed to get queue latency for #{queue_name}: #{e.message}")
        0.0
      end
    end

    def get_processing_metrics(queue_name)
      in_process_jobs = 0
      oldest_runtime_seconds = 0.0
      now = Time.current
      stale_runtime_threshold = stale_runtime_threshold_seconds

      begin
        Sidekiq::WorkSet.new.each do |_process_id, _thread_id, work|
          payload = Ops::SidekiqJobStateTracker.payload_hash(work.payload)
          next unless payload["queue"].to_s == queue_name.to_s

          in_process_jobs += 1
          runtime_seconds = [ (now - work.run_at), 0 ].max
          oldest_runtime_seconds = [ oldest_runtime_seconds, runtime_seconds ].max
        end
      rescue StandardError => e
        Rails.logger.warn("[JobHealthMonitor] Failed to get processing metrics for #{queue_name}: #{e.message}")
      end

      {
        in_process_jobs: in_process_jobs,
        oldest_in_process_runtime_seconds: oldest_runtime_seconds.round(2),
        stale_processing: oldest_runtime_seconds >= stale_runtime_threshold
      }
    end

    def calculate_health_score(queue_size, recent_failures, queue_latency_seconds:, in_process_jobs:, oldest_in_process_runtime_seconds:)
      base_score = 100

      # Deduct points for queue backlog
      if queue_size > 1000
        base_score -= 30
      elsif queue_size > 500
        base_score -= 20
      elsif queue_size > 100
        base_score -= 10
      end

      # Deduct points for recent failures
      if recent_failures > 100
        base_score -= 40
      elsif recent_failures > 50
        base_score -= 25
      elsif recent_failures > 10
        base_score -= 15
      elsif recent_failures > 0
        base_score -= 5
      end

      # Deduct points for queue wait and stale in-process jobs.
      if queue_latency_seconds > 600
        base_score -= 20
      elsif queue_latency_seconds > 300
        base_score -= 12
      elsif queue_latency_seconds > 120
        base_score -= 6
      end

      if queue_size.positive? && in_process_jobs.zero?
        base_score -= 20
      end

      if oldest_in_process_runtime_seconds >= stale_runtime_threshold_seconds
        base_score -= 25
      elsif oldest_in_process_runtime_seconds >= (stale_runtime_threshold_seconds / 2.0)
        base_score -= 12
      end

      [ base_score, 0 ].max
    end

    def determine_primary_issue(queue_size, recent_failures, queue_latency_seconds:, in_process_jobs:, oldest_in_process_runtime_seconds:)
      if recent_failures > 50
        "high_failure_rate"
      elsif queue_size.positive? && in_process_jobs.zero?
        "no_consumer_activity"
      elsif oldest_in_process_runtime_seconds >= stale_runtime_threshold_seconds
        "stale_in_process_job"
      elsif queue_latency_seconds > 300
        "high_queue_latency"
      elsif queue_size > 500
        "queue_backlog"
      elsif recent_failures > 10
        "elevated_failures"
      elsif queue_size > 100
        "moderate_backlog"
      else
        "healthy"
      end
    end

    def stale_runtime_threshold_seconds
      ENV.fetch("JOB_STALE_RUNTIME_THRESHOLD_SECONDS", 900).to_i.clamp(60, 86_400)
    end

    def health_status_label(score)
      case score
      when 90..100
        "excellent"
      when 75..89
        "good"
      when 60..74
        "fair"
      when 40..59
        "poor"
      else
        "critical"
      end
    end

    def cleanup_orphaned_job_metadata
      cleaned_count = 0

      # Find posts with workspace_actions metadata pointing to non-existent jobs
      posts_with_orphaned_jobs = InstagramProfilePost.where(
        "metadata->'workspace_actions'->>'job_id' IS NOT NULL"
      )

      posts_with_orphaned_jobs.find_each do |post|
        metadata = post.metadata.is_a?(Hash) ? post.metadata : {}
        workspace_actions = metadata["workspace_actions"].is_a?(Hash) ? metadata["workspace_actions"] : {}
        job_id = workspace_actions["job_id"]

        if job_id.present?
          # Check if job still exists or is recent
          job_exists = check_job_existence(job_id)

          unless job_exists
            # Clean up orphaned job metadata
            workspace_actions.delete("job_id")
            workspace_actions.delete("queue_name")
            workspace_actions.delete("last_enqueued_at")
            workspace_actions["status"] = "orphaned_cleaned"
            metadata["workspace_actions"] = workspace_actions

            post.update!(metadata: metadata)
            cleaned_count += 1
          end
        end
      end

      cleaned_count
    end

    def check_job_existence(job_id)
      # Check if job exists in recent failures or is very recent
      recent_failure = BackgroundJobFailure.where(active_job_id: job_id)
        .where("occurred_at > ?", 1.hour.ago)
        .exists?

      return true if recent_failure

      # Could also check Sidekiq API for active/recent jobs
      # For now, assume jobs older than 1 hour without failure record are gone
      false
    end

    def get_top_error_patterns
      BackgroundJobFailure
        .where("occurred_at > ?", 7.days.ago)
        .group(:error_class, :job_class)
        .select("error_class, job_class, COUNT(*) as failure_count")
        .order("failure_count DESC")
        .limit(10)
        .map { |r| { error_class: r.error_class, job_class: r.job_class, count: r.failure_count } }
    end

    def get_failing_job_patterns
      BackgroundJobFailure
        .where("occurred_at > ?", 7.days.ago)
        .group(:job_class)
        .select("job_class, COUNT(*) as failure_count, COUNT(DISTINCT error_class) as error_variety")
        .order("failure_count DESC")
        .limit(10)
        .map { |r| { job_class: r.job_class, count: r.failure_count, error_variety: r.error_variety } }
    end

    def get_hourly_failure_trends
      BackgroundJobFailure
        .where("occurred_at > ?", 24.hours.ago)
        .group("DATE_TRUNC('hour', occurred_at)")
        .select("DATE_TRUNC('hour', occurred_at) as hour, COUNT(*) as failures")
        .order("hour")
        .map { |r| { hour: r.hour, failures: r.failures } }
    end

    def generate_recommendations(patterns)
      recommendations = []

      # Analyze top errors
      top_error = patterns[:top_errors].first
      if top_error && top_error[:count] > 100
        recommendations << {
          priority: "high",
          type: "error_pattern",
          message: "Investigate #{top_error[:error_class]} in #{top_error[:job_class]} (#{top_error[:count]} failures)"
        }
      end

      # Analyze failing jobs
      failing_job = patterns[:failing_jobs].first
      if failing_job && failing_job[:count] > 200
        recommendations << {
          priority: "high",
          type: "job_stability",
          message: "Review #{failing_job[:job_class]} stability (#{failing_job[:count]} failures, #{failing_job[:error_variety]} error types)"
        }
      end

      # Analyze trends
      recent_trend = patterns[:hourly_trends].last(4)
      if recent_trend.all? { |t| t[:failures] > 100 }
        recommendations << {
          priority: "medium",
          type: "trend",
          message: "Elevated failure rate detected in recent hours"
        }
      end

      recommendations
    end

    def alert_critical_queue_issues(issues)
      issues.each do |issue|
        Ops::StructuredLogger.error(
          event: "job.queue_critical_issue",
          payload: {
            queue: issue[:queue],
            issue: issue[:issue],
            health_score: issue[:score],
            alert_level: "critical"
          }
        )
      end
    end
  end
end
