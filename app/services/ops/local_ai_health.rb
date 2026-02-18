module Ops
  class LocalAiHealth
    CACHE_KEY = "ops:local_ai_health:v1".freeze
    CACHE_TTL = 45.seconds

    class << self
      def check(force: false)
        cached = Rails.cache.read(CACHE_KEY)
        return cached if cached.present? && !force

        started_at = monotonic_started_at
        checked_at = Time.current

        microservice = Ai::LocalMicroserviceClient.new.test_connection!
        ollama = Ai::OllamaClient.new.test_connection!

        ok = ActiveModel::Type::Boolean.new.cast(microservice[:ok]) && ActiveModel::Type::Boolean.new.cast(ollama[:ok])
        result = {
          ok: ok,
          checked_at: checked_at.iso8601(3),
          details: {
            microservice: microservice,
            ollama: ollama
          }
        }

        Rails.cache.write(CACHE_KEY, result, expires_in: CACHE_TTL)

        if ok
          Ai::ApiUsageTracker.track_success(
            provider: "local_ai_stack",
            operation: "health_check",
            category: "healthcheck",
            started_at: started_at,
            metadata: result[:details]
          )
        else
          Ai::ApiUsageTracker.track_failure(
            provider: "local_ai_stack",
            operation: "health_check",
            category: "healthcheck",
            started_at: started_at,
            error: "One or more local AI components are unavailable",
            metadata: result[:details]
          )
        end

        result
      rescue StandardError => e
        failure = {
          ok: false,
          checked_at: Time.current.iso8601(3),
          error: e.message.to_s,
          error_class: e.class.name
        }

        Rails.cache.write(CACHE_KEY, failure, expires_in: 10.seconds)

        Ai::ApiUsageTracker.track_failure(
          provider: "local_ai_stack",
          operation: "health_check",
          category: "healthcheck",
          started_at: started_at,
          error: "#{e.class}: #{e.message}",
          metadata: failure
        )

        failure
      end

      private

      def monotonic_started_at
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      rescue StandardError
        Time.current.to_f
      end
    end
  end
end
