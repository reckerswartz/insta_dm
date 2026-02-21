require "sidekiq"
require "sidekiq/cron/job"

redis_url = ENV.fetch("REDIS_URL", "redis://127.0.0.1:6379/0")

# Job monitoring middleware
class SidekiqJobMonitor
  def call(worker, msg, queue)
    start_time = Time.current
    job_class = msg["class"]
    job_id = msg["jid"]

    Rails.logger.info("[sidekiq] Starting job: #{job_class} (#{job_id}) on queue #{queue}")

    yield

    duration = Time.current - start_time
    Rails.logger.info("[sidekiq] Completed job: #{job_class} (#{job_id}) in #{duration.round(2)}s")

    # Log slow jobs
    if duration > 300 # 5 minutes
      Rails.logger.warn("[sidekiq] Slow job detected: #{job_class} took #{duration.round(2)}s")
    end
  rescue StandardError => e
    duration = Time.current - start_time
    Rails.logger.error("[sidekiq] Failed job: #{job_class} (#{job_id}) after #{duration.round(2)}s: #{e.class}: #{e.message}")
    raise
  end
end

Sidekiq.configure_server do |config|
  config.redis = { url: redis_url, reconnect_attempts: 3, network_timeout: 5 }

  # Isolate local compute-heavy workloads from general queue throughput.
  if config.respond_to?(:capsule)
    frame_concurrency = ENV.fetch("SIDEKIQ_FRAME_CONCURRENCY", 1).to_i.clamp(1, 4)
    story_auto_reply_orchestration_concurrency = ENV.fetch("SIDEKIQ_STORY_AUTO_REPLY_ORCHESTRATION_CONCURRENCY", 1).to_i.clamp(1, 4)
    profile_story_orchestration_concurrency = ENV.fetch("SIDEKIQ_PROFILE_STORY_ORCHESTRATION_CONCURRENCY", 1).to_i.clamp(1, 4)
    home_story_orchestration_concurrency = ENV.fetch("SIDEKIQ_HOME_STORY_ORCHESTRATION_CONCURRENCY", 1).to_i.clamp(1, 3)
    home_story_sync_concurrency = ENV.fetch("SIDEKIQ_HOME_STORY_SYNC_CONCURRENCY", 1).to_i.clamp(1, 4)
    story_processing_concurrency = ENV.fetch("SIDEKIQ_STORY_PROCESSING_CONCURRENCY", 1).to_i.clamp(1, 4)
    story_preview_generation_concurrency = ENV.fetch("SIDEKIQ_STORY_PREVIEW_GENERATION_CONCURRENCY", 1).to_i.clamp(1, 4)
    story_replies_concurrency = ENV.fetch("SIDEKIQ_STORY_REPLIES_CONCURRENCY", 1).to_i.clamp(1, 4)
    profile_reevaluation_concurrency = ENV.fetch("SIDEKIQ_PROFILE_REEVALUATION_CONCURRENCY", 1).to_i.clamp(1, 2)
    story_validation_concurrency = ENV.fetch("SIDEKIQ_STORY_VALIDATION_CONCURRENCY", 1).to_i.clamp(1, 4)
    Ops::AiServiceQueueRegistry.sidekiq_capsules.each do |capsule|
      config.capsule(capsule[:capsule_name]) do |cap|
        cap.concurrency = capsule[:concurrency].to_i
        cap.queues = [ capsule[:queue_name].to_s ]
      end
    end

    config.capsule("frame_generation_lane") do |cap|
      cap.concurrency = frame_concurrency
      cap.queues = %w[frame_generation]
    end

    config.capsule("story_auto_reply_orchestration_lane") do |cap|
      cap.concurrency = story_auto_reply_orchestration_concurrency
      cap.queues = %w[story_auto_reply_orchestration]
    end

    config.capsule("profile_story_orchestration_lane") do |cap|
      cap.concurrency = profile_story_orchestration_concurrency
      cap.queues = %w[profile_story_orchestration]
    end

    config.capsule("home_story_orchestration_lane") do |cap|
      cap.concurrency = home_story_orchestration_concurrency
      cap.queues = %w[home_story_orchestration]
    end

    config.capsule("home_story_sync_lane") do |cap|
      cap.concurrency = home_story_sync_concurrency
      cap.queues = %w[home_story_sync]
    end

    config.capsule("story_processing_lane") do |cap|
      cap.concurrency = story_processing_concurrency
      cap.queues = %w[story_processing]
    end

    config.capsule("story_preview_generation_lane") do |cap|
      cap.concurrency = story_preview_generation_concurrency
      cap.queues = %w[story_preview_generation]
    end

    config.capsule("story_replies_lane") do |cap|
      cap.concurrency = story_replies_concurrency
      cap.queues = %w[story_replies]
    end

    config.capsule("profile_reevaluation_lane") do |cap|
      cap.concurrency = profile_reevaluation_concurrency
      cap.queues = %w[profile_reevaluation]
    end

    config.capsule("story_validation_lane") do |cap|
      cap.concurrency = story_validation_concurrency
      cap.queues = %w[story_validation]
    end
  end

  # Enhanced error handling with better categorization
  config.error_handlers << proc do |error, context, _|
    error_category = categorize_error(error)

    Ops::StructuredLogger.error(
      event: "sidekiq.error",
      payload: {
        error_class: error.class.name,
        error_message: error.message,
        queue: context[:queue],
        jid: context[:jid],
        class: context[:class],
        error_category: error_category,
        retry_count: context[:retry_count],
        created_at: context[:created_at]
      }
    )

    # Alert on critical errors
    if error_category == "critical"
      alert_critical_error(error, context)
    end
  rescue StandardError
    Rails.logger.error("[sidekiq] error handler failed for #{error.class}: #{error.message}")
  end

  # Add middleware for job monitoring
  config.server_middleware do |chain|
    chain.add SidekiqJobMonitor
  end

  schedule_path = Rails.root.join("config/sidekiq_schedule.yml")
  next unless File.exist?(schedule_path)

  begin
    raw = YAML.safe_load(ERB.new(File.read(schedule_path)).result, aliases: true) || {}
    env_schedule = raw.fetch(Rails.env, {})
    payload = env_schedule.to_h.transform_values { |entry| entry.to_h.stringify_keys }
    Sidekiq::Cron::Job.load_from_hash!(payload) if payload.present?
  rescue StandardError => e
    Rails.logger.error("[sidekiq] failed to load cron schedule: #{e.class}: #{e.message}")
  end
end

Sidekiq.configure_client do |config|
  config.redis = { url: redis_url, reconnect_attempts: 3, network_timeout: 5 }
end

# Error categorization helper
def categorize_error(error)
  case error
  when Instagram::AuthenticationRequiredError
    "authentication"
  when ActiveRecord::ConnectionTimeoutError, Net::TimeoutError
    "timeout"
  when ActiveRecord::RecordNotFound, ActiveRecord::RecordInvalid
    "data"
  when NoMethodError, TypeError
    "code"
  when StandardError
    if error.message.to_s.include?("memory") || error.message.to_s.include?("stack level too deep")
      "critical"
    else
      "runtime"
    end
  else
    "unknown"
  end
end

# Critical error alerting
def alert_critical_error(error, context)
  # This could integrate with external monitoring systems
  Rails.logger.error("[CRITICAL] Job failure: #{context[:class]} - #{error.class}: #{error.message}")

  # Example: Send to external monitoring service
  # MonitoringService.alert_critical_job_error(error, context) if defined?(MonitoringService)
end
