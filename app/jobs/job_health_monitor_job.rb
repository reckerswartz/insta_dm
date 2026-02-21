class JobHealthMonitorJob < ApplicationJob
  queue_as :maintenance

  # Run every 5 minutes to monitor job health
  def perform
    check_queue_health
    check_failure_patterns
    check_resource_utilization
    generate_health_report
  end

  private

  def check_queue_health
    Sidekiq::Queue.all.each do |queue|
      size = queue.size
      next if size == 0

      if size > 100
        Ops::StructuredLogger.warn(
          event: "job.queue_congestion",
          payload: {
            queue_name: queue.name,
            queue_size: size,
            severity: size > 500 ? "critical" : "warning"
          }
        )
      end
    end

    # Check retry set size
    retry_size = Sidekiq::RetrySet.new.size
    if retry_size > 50
      Ops::StructuredLogger.warn(
        event: "job.retry_set_large",
        payload: {
          retry_set_size: retry_size,
          severity: retry_size > 200 ? "critical" : "warning"
        }
      )
    end
  end

  def check_failure_patterns
    # Check recent failures by error class
    recent_failures = BackgroundJobFailure.where('occurred_at > ?', 1.hour.ago)
    
    failure_counts = recent_failures.group(:error_class).count
    failure_counts.each do |error_class, count|
      if count > 10
        Ops::StructuredLogger.warn(
          event: "job.error_spike",
          payload: {
            error_class: error_class,
            count: count,
            time_window: "1_hour",
            severity: count > 50 ? "critical" : "warning"
          }
        )
      end
    end

    # Check for specific problematic patterns
    check_authentication_failures(recent_failures)
    check_timeout_failures(recent_failures)
    check_resource_failures(recent_failures)
  end

  def check_authentication_failures(failures)
    auth_failures = failures.where(error_class: 'Instagram::AuthenticationRequiredError')
    return unless auth_failures.count > 5

    # Group by account to identify problematic accounts
    account_failures = auth_failures.group(:instagram_account_id).count
    account_failures.each do |account_id, count|
      next unless count > 3

      Ops::StructuredLogger.warn(
        event: "job.account_authentication_issues",
        payload: {
          instagram_account_id: account_id,
          failure_count: count,
          time_window: "1_hour",
          severity: count > 10 ? "critical" : "warning"
        }
      )
    end
  end

  def check_timeout_failures(failures)
    timeout_errors = failures.where('error_class ILIKE ?', '%Timeout%')
    return unless timeout_errors.count > 5

    Ops::StructuredLogger.warn(
      event: "job.timeout_spike",
      payload: {
        timeout_count: timeout_errors.count,
        time_window: "1_hour",
        severity: timeout_errors.count > 20 ? "critical" : "warning"
      }
    )
  end

  def check_resource_failures(failures)
    resource_errors = failures.where('error_message ILIKE ?', '%resource%')
    return unless resource_errors.count > 3

    Ops::StructuredLogger.warn(
      event: "job.resource_constraints",
      payload: {
        resource_error_count: resource_errors.count,
        time_window: "1_hour",
        severity: resource_errors.count > 10 ? "critical" : "warning"
      }
    )
  end

  def check_resource_utilization
    # Check Sidekiq process health
    process_count = Sidekiq::ProcessSet.new.size
    if process_count == 0
      Ops::StructuredLogger.error(
        event: "job.no_sidekiq_processes",
        payload: {
          severity: "critical"
        }
      )
    end

    # Check worker utilization
    busy_workers = Sidekiq::Workers.new.size
    if busy_workers > 50
      Ops::StructuredLogger.warn(
        event: "job.high_worker_utilization",
        payload: {
          busy_workers: busy_workers,
          severity: busy_workers > 100 ? "critical" : "warning"
        }
      )
    end
  end

  def generate_health_report
    report = {
      timestamp: Time.current.iso8601,
      queue_health: collect_queue_metrics,
      failure_summary: collect_failure_metrics,
      resource_metrics: collect_resource_metrics,
      recommendations: generate_recommendations
    }

    # Store health report for monitoring
    Rails.cache.write('job_health_report', report, expires_in: 10.minutes)

    # Log summary
    Ops::StructuredLogger.info(
      event: "job.health_report",
      payload: {
        total_queues: report[:queue_health][:total_queues],
        congested_queues: report[:queue_health][:congested_queues],
        total_failures: report[:failure_summary][:total_failures],
        active_processes: report[:resource_metrics][:active_processes],
        recommendations_count: report[:recommendations].length
      }
    )
  end

  def collect_queue_metrics
    queues = Sidekiq::Queue.all
    total_size = queues.sum(&:size)
    congested = queues.select { |q| q.size > 100 }

    {
      total_queues: queues.size,
      total_size: total_size,
      congested_queues: congested.size,
      largest_queue: queues.max_by(&:size)&.name,
      largest_queue_size: queues.map(&:size).max || 0
    }
  end

  def collect_failure_metrics
    recent_failures = BackgroundJobFailure.where('occurred_at > ?', 1.hour.ago)
    
    {
      total_failures: recent_failures.count,
      unique_error_classes: recent_failures.distinct.count(:error_class),
      top_error_class: recent_failures.group(:error_class).count.max_by(&:last)&.first,
      authentication_failures: recent_failures.where(error_class: 'Instagram::AuthenticationRequiredError').count,
      timeout_failures: recent_failures.where('error_class ILIKE ?', '%Timeout%').count
    }
  end

  def collect_resource_metrics
    {
      active_processes: Sidekiq::ProcessSet.new.size,
      busy_workers: Sidekiq::Workers.new.size,
      retry_set_size: Sidekiq::RetrySet.new.size,
      scheduled_set_size: Sidekiq::ScheduledSet.new.size
    }
  end

  def generate_recommendations
    recommendations = []
    
    # Queue recommendations
    queue_metrics = collect_queue_metrics
    if queue_metrics[:congested_queues] > 0
      recommendations << "Consider increasing worker count for congested queues"
    end

    # Failure recommendations
    failure_metrics = collect_failure_metrics
    if failure_metrics[:authentication_failures] > 10
      recommendations << "Review Instagram account authentication for multiple failing accounts"
    end

    if failure_metrics[:timeout_failures] > 5
      recommendations << "Investigate timeout issues - may need to increase timeouts or fix slow operations"
    end

    # Resource recommendations
    resource_metrics = collect_resource_metrics
    if resource_metrics[:active_processes] == 0
      recommendations << "CRITICAL: No Sidekiq processes running - restart Sidekiq immediately"
    end

    if resource_metrics[:retry_set_size] > 100
      recommendations << "Large retry set detected - consider manual intervention for stuck jobs"
    end

    recommendations
  end
end
