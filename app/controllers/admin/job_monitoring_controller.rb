class Admin::JobMonitoringController < Admin::BaseController
  before_action :require_admin

  def index
    @health_report = JobHealthMonitor.check_queue_health!
    @failure_patterns = JobHealthMonitor.analyze_failure_patterns
    @recent_failures = BackgroundJobFailure.recent_first.limit(50)
    
    # Calculate summary stats
    @summary_stats = calculate_summary_stats
  end

  def queue_details
    queue_name = params[:queue_id]
    @queue_name = queue_name
    
    # Get queue-specific details
    @queue_failures = BackgroundJobFailure
      .where(queue_name: queue_name)
      .where("occurred_at > ?", 24.hours.ago)
      .order(occurred_at: :desc)
      .limit(100)
    
    @queue_stats = calculate_queue_stats(queue_name)
    @error_breakdown = calculate_error_breakdown(queue_name)
  end

  def cleanup_jobs
    cleanup_stats = JobHealthMonitor.cleanup_stale_jobs!
    
    redirect_to admin_job_monitoring_path,
      notice: "Cleanup completed: #{cleanup_stats[:cleaned_jobs]} jobs cleaned, #{cleanup_stats[:cleaned_failures]} failures removed"
  end

  def retry_failed_jobs
    job_class = params[:job_class]
    error_class = params[:error_class]
    limit = params[:limit].to_i.clamp(1, 100)

    retried_count = 0
    failures_to_retry = BackgroundJobFailure
      .where(job_class: job_class)
      .where(error_class: error_class)
      .where(retryable: true)
      .where("occurred_at > ?", 24.hours.ago)
      .limit(limit)

    failures_to_retry.each do |failure|
      begin
        # Attempt to retry the job
        retry_job_failure(failure)
        retried_count += 1
      rescue StandardError => e
        Rails.logger.error("Failed to retry job #{failure.active_job_id}: #{e.class}: #{e.message}")
      end
    end

    redirect_back(
      fallback_location: admin_job_monitoring_path,
      notice: "Retried #{retried_count} out of #{failures_to_retry.count} selected jobs"
    )
  end

  def job_details
    @failure = BackgroundJobFailure.find(params[:id])
    
    # Find related failures
    @related_failures = BackgroundJobFailure
      .where(job_class: @failure.job_class)
      .where("occurred_at > ?", 24.hours.ago)
      .where.not(id: @failure.id)
      .order(occurred_at: :desc)
      .limit(10)
  end

  private

  def calculate_summary_stats
    {
      total_failures_24h: BackgroundJobFailure.where("occurred_at > ?", 24.hours.ago).count,
      total_failures_7d: BackgroundJobFailure.where("occurred_at > ?", 7.days.ago).count,
      unique_failing_jobs_24h: BackgroundJobFailure.where("occurred_at > ?", 24.hours.ago).distinct.count(:job_class),
      authentication_failures_24h: BackgroundJobFailure.where(failure_kind: "authentication").where("occurred_at > ?", 24.hours.ago).count,
      transient_failures_24h: BackgroundJobFailure.where(failure_kind: "transient").where("occurred_at > ?", 24.hours.ago).count,
      runtime_failures_24h: BackgroundJobFailure.where(failure_kind: "runtime").where("occurred_at > ?", 24.hours.ago).count
    }
  end

  def calculate_queue_stats(queue_name)
    recent_failures = BackgroundJobFailure
      .where(queue_name: queue_name)
      .where("occurred_at > ?", 24.hours.ago)
    
    {
      total_failures: recent_failures.count,
      unique_errors: recent_failures.distinct.count(:error_class),
      retryable_failures: recent_failures.where(retryable: true).count,
      auth_failures: recent_failures.where(failure_kind: "authentication").count,
      avg_failures_per_hour: calculate_hourly_average(recent_failures)
    }
  end

  def calculate_error_breakdown(queue_name)
    BackgroundJobFailure
      .where(queue_name: queue_name)
      .where("occurred_at > ?", 24.hours.ago)
      .group(:error_class)
      .select("error_class, COUNT(*) as count")
      .order("count DESC")
      .limit(10)
  end

  def calculate_hourly_average(failures)
    return 0 if failures.none?
    
    hours_span = ((failures.maximum(:occurred_at) - failures.minimum(:occurred_at)) / 1.hour).ceil
    hours_span = 1 if hours_span == 0
    
    (failures.count.to_f / hours_span).round(2)
  end

  def retry_job_failure(failure)
    Jobs::FailureRetry.enqueue!(failure, source: "admin_manual_retry")
    true
  rescue Jobs::FailureRetry::RetryError => e
    Rails.logger.warn("Retry skipped for failure #{failure.id}: #{e.message}")
    false
  end
end
