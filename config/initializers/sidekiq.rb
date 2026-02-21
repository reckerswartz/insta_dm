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
    legacy_ai_concurrency = ENV.fetch("SIDEKIQ_AI_CONCURRENCY", 2).to_i.clamp(1, 4)
    visual_concurrency = ENV.fetch("SIDEKIQ_AI_VISUAL_CONCURRENCY", 3).to_i.clamp(1, 5)
    face_concurrency = ENV.fetch("SIDEKIQ_AI_FACE_CONCURRENCY", 3).to_i.clamp(1, 4)
    ocr_concurrency = ENV.fetch("SIDEKIQ_AI_OCR_CONCURRENCY", 2).to_i.clamp(1, 3)
    video_concurrency = ENV.fetch("SIDEKIQ_AI_VIDEO_CONCURRENCY", 2).to_i.clamp(1, 3)
    metadata_concurrency = ENV.fetch("SIDEKIQ_AI_METADATA_CONCURRENCY", 2).to_i.clamp(1, 4)
    frame_concurrency = ENV.fetch("SIDEKIQ_FRAME_CONCURRENCY", 2).to_i.clamp(1, 4)

    config.capsule("ai_legacy_lane") do |cap|
      cap.concurrency = legacy_ai_concurrency
      cap.queues = %w[ai]
    end

    config.capsule("ai_visual_lane") do |cap|
      cap.concurrency = visual_concurrency
      cap.queues = %w[ai_visual_queue]
    end

    config.capsule("ai_face_lane") do |cap|
      cap.concurrency = face_concurrency
      cap.queues = %w[ai_face_queue]
    end

    config.capsule("ai_ocr_lane") do |cap|
      cap.concurrency = ocr_concurrency
      cap.queues = %w[ai_ocr_queue]
    end

    config.capsule("ai_video_lane") do |cap|
      cap.concurrency = video_concurrency
      cap.queues = %w[video_processing_queue]
    end

    config.capsule("ai_metadata_lane") do |cap|
      cap.concurrency = metadata_concurrency
      cap.queues = %w[ai_metadata_queue]
    end

    config.capsule("frame_generation_lane") do |cap|
      cap.concurrency = frame_concurrency
      cap.queues = %w[frame_generation]
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
