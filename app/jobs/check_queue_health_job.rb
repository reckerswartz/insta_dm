class CheckQueueHealthJob < ApplicationJob
  queue_as :maintenance

  THROTTLE_SECONDS = ENV.fetch("QUEUE_HEALTH_CHECK_MIN_INTERVAL_SECONDS", 90).to_i.clamp(30, 900)

  def perform(force: false)
    return if throttled?(force: force)

    Ops::QueueHealth.check!
    mark_checked!
  end

  private

  def throttled?(force:)
    return false if ActiveModel::Type::Boolean.new.cast(force)

    last_checked_at = read_last_checked_at
    return false unless last_checked_at.is_a?(Time)

    last_checked_at >= THROTTLE_SECONDS.seconds.ago
  rescue StandardError
    false
  end

  def mark_checked!
    timestamp = Time.current
    Rails.cache.write(throttle_cache_key, timestamp, expires_in: 2.hours)
    self.class.instance_variable_set(:@last_checked_at_fallback, timestamp)
  rescue StandardError
    nil
  end

  def throttle_cache_key
    "ops:check_queue_health_job:last_checked_at"
  end

  def read_last_checked_at
    Rails.cache.read(throttle_cache_key) || self.class.instance_variable_get(:@last_checked_at_fallback)
  rescue StandardError
    self.class.instance_variable_get(:@last_checked_at_fallback)
  end
end
