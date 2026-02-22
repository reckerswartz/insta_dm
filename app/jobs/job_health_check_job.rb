class JobHealthCheckJob < ApplicationJob
  queue_as :default

  def perform
    Rails.logger.info("[JobHealthCheckJob] Starting job health monitoring")

    # Check queue health
    health_report = JobHealthMonitor.check_queue_health!
    
    # Clean up stale jobs (run less frequently)
    if Time.current.minute % 30 == 0 # Every 30 minutes
      cleanup_stats = JobHealthMonitor.cleanup_stale_jobs!
    end

    # Analyze failure patterns (run hourly)
    if Time.current.minute == 0
      patterns = JobHealthMonitor.analyze_failure_patterns
    end

    Rails.logger.info("[JobHealthCheckJob] Health monitoring completed")
  rescue StandardError => e
    Rails.logger.error("[JobHealthCheckJob] Health monitoring failed: #{e.class}: #{e.message}")
    raise
  end
end
