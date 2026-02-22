class Admin::BackgroundJobsController < Admin::BaseController
  def dashboard
    snapshot = Admin::BackgroundJobs::DashboardSnapshot.new(backend: queue_backend).call

    @backend = snapshot.backend
    @counts = snapshot.counts
    @processes = snapshot.processes
    @recent_jobs = snapshot.recent_jobs
    @recent_failed = snapshot.recent_failed
    @ai_service_queue_metrics = Ops::AiServiceQueueMetrics.snapshot
    @queue_estimates = Ops::QueueProcessingEstimator.snapshot(backend: @backend)
    @job_execution_metrics = Ops::JobExecutionMetricsSnapshot.snapshot

    Admin::BackgroundJobs::RecentJobDetailsEnricher.new(rows: @recent_jobs).call

    @failure_logs = BackgroundJobFailure.recent_first.limit(100)
    @recent_issues = AppIssue.recent_first.limit(15)
    @recent_storage_ingestions = ActiveStorageIngestion.recent_first.limit(15)
  end

  def failures
    @q = params[:q].to_s.strip
    result = Admin::BackgroundJobs::FailuresQuery.new(params: params).call
    @failures = result.failures

    respond_to do |format|
      format.html
      format.json do
        render json: Admin::BackgroundJobs::FailurePayloadBuilder.new(
          failures: @failures,
          total: result.total,
          pages: result.pages
        ).call
      end
    end
  end

  def failure
    @failure = BackgroundJobFailure.find(params[:id])
  end

  def retry_failure
    failure = BackgroundJobFailure.find(params[:id])
    Jobs::FailureRetry.enqueue!(failure)

    Ops::LiveUpdateBroadcaster.broadcast!(
      topic: "job_failures_changed",
      account_id: failure.instagram_account_id,
      payload: { action: "retry", failure_id: failure.id },
      throttle_key: "job_failures_changed",
      throttle_seconds: 0
    )

    respond_to do |format|
      format.html { redirect_to admin_background_job_failure_path(failure), notice: "Retry queued for #{failure.job_class}." }
      format.json { render json: { ok: true } }
    end
  rescue Jobs::FailureRetry::RetryError => e
    respond_to do |format|
      format.html { redirect_to admin_background_job_failure_path(params[:id]), alert: e.message }
      format.json { render json: { ok: false, error: e.message }, status: :unprocessable_entity }
    end
  end

  def clear_all_jobs
    Admin::BackgroundJobs::QueueClearer.new(backend: queue_backend).call

    Ops::LiveUpdateBroadcaster.broadcast!(
      topic: "jobs_changed",
      payload: { action: "clear_all" },
      throttle_key: "jobs_changed",
      throttle_seconds: 0
    )

    redirect_to admin_background_jobs_path, notice: "All jobs have been stopped and queue cleared successfully."
  rescue StandardError => e
    redirect_to admin_background_jobs_path, alert: "Failed to clear jobs: #{e.message}"
  end

  private

  def queue_backend
    Rails.application.config.active_job.queue_adapter.to_s
  rescue StandardError
    "unknown"
  end
end
