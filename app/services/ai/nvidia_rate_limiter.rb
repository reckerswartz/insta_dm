module Ai
  # Redis-backed token bucket per (provider, role) so bursts of Sidekiq jobs
  # don't exceed NVIDIA Build's per-model RPM quota. Degrades to a no-op if
  # Redis is unavailable or the setting has no rate_limit_rpm configured.
  class NvidiaRateLimiter
    class Rejected < StandardError; end

    DEFAULT_WAIT_SECONDS = 30.0
    SLEEP_INCREMENT_SECONDS = 0.1

    def initialize(redis: nil, clock: Time, logger: Rails.logger)
      @redis = redis
      @clock = clock
      @logger = logger
    end

    # Blocks (with a cap) until a token is available. Raises Rejected if
    # the call couldn't acquire a token within max_wait_seconds.
    def throttle!(setting:, max_wait_seconds: DEFAULT_WAIT_SECONDS)
      return unless setting

      rpm = setting.rate_limit_rpm.to_i
      return if rpm <= 0

      waited = 0.0
      while waited < max_wait_seconds
        return if try_consume(setting: setting, rpm: rpm)

        sleep(SLEEP_INCREMENT_SECONDS)
        waited += SLEEP_INCREMENT_SECONDS
      end

      raise Rejected, "NVIDIA rate limit for #{setting.display_name} exceeded (rpm=#{rpm}); waited #{waited}s"
    end

    private

    attr_reader :clock, :logger

    # Sliding-window counter: INCR a per-minute key, EXPIRE it at 60s.
    # If INCR result > rpm, reject. Redis-less installs just pass through.
    def try_consume(setting:, rpm:)
      r = redis_client
      return true unless r

      minute_bucket = (clock.now.to_i / 60)
      key = "ai:nvidia:rl:#{setting.id}:#{minute_bucket}"
      count = r.incr(key)
      r.expire(key, 65) if count == 1
      count <= rpm
    rescue StandardError => e
      # If Redis goes away we prefer to let the request through rather
      # than stall the whole worker on a bookkeeping failure.
      logger&.warn("NvidiaRateLimiter redis error (fail-open): #{e.class}: #{e.message}")
      true
    end

    def redis_client
      @redis ||= begin
        require "redis"
        Redis.new(url: ENV.fetch("REDIS_URL", "redis://localhost:6379/0"))
      rescue LoadError
        nil
      end
    end
  end
end
