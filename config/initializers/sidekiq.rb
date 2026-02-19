require "sidekiq"
require "sidekiq/cron/job"

redis_url = ENV.fetch("REDIS_URL", "redis://127.0.0.1:6379/0")

Sidekiq.configure_server do |config|
  config.redis = { url: redis_url }

  # Isolate local compute-heavy workloads from general queue throughput.
  if config.respond_to?(:capsule)
    legacy_ai_concurrency = ENV.fetch("SIDEKIQ_AI_CONCURRENCY", 1).to_i.clamp(1, 2)
    visual_concurrency = ENV.fetch("SIDEKIQ_AI_VISUAL_CONCURRENCY", 2).to_i.clamp(1, 3)
    face_concurrency = ENV.fetch("SIDEKIQ_AI_FACE_CONCURRENCY", 2).to_i.clamp(1, 2)
    ocr_concurrency = ENV.fetch("SIDEKIQ_AI_OCR_CONCURRENCY", 1).to_i.clamp(1, 1)
    video_concurrency = ENV.fetch("SIDEKIQ_AI_VIDEO_CONCURRENCY", 1).to_i.clamp(1, 1)
    metadata_concurrency = ENV.fetch("SIDEKIQ_AI_METADATA_CONCURRENCY", 1).to_i.clamp(1, 2)
    frame_concurrency = ENV.fetch("SIDEKIQ_FRAME_CONCURRENCY", 1).to_i.clamp(1, 2)

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

  config.error_handlers << proc do |error, context, _|
    Ops::StructuredLogger.error(
      event: "sidekiq.error",
      payload: {
        error_class: error.class.name,
        error_message: error.message,
        queue: context[:queue],
        jid: context[:jid],
        class: context[:class]
      }
    )
  rescue StandardError
    Rails.logger.error("[sidekiq] error handler failed for #{error.class}: #{error.message}")
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
  config.redis = { url: redis_url }
end
