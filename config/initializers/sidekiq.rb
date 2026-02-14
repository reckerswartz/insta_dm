require "sidekiq"
require "sidekiq/cron/job"

redis_url = ENV.fetch("REDIS_URL", "redis://127.0.0.1:6379/0")

Sidekiq.configure_server do |config|
  config.redis = { url: redis_url }

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
