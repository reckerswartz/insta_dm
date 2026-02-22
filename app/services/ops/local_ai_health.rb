module Ops
  class LocalAiHealth
    CACHE_KEY = "ops:local_ai_health:v1".freeze
    CACHE_TTL = ENV.fetch("AI_HEALTH_CACHE_TTL_SECONDS", "900").to_i.seconds
    FAILURE_CACHE_TTL = ENV.fetch("AI_HEALTH_FAILURE_CACHE_TTL_SECONDS", "60").to_i.seconds
    STALE_AFTER = ENV.fetch("AI_HEALTH_STALE_AFTER_SECONDS", "240").to_i.seconds

    class << self
      def status
        cached = Rails.cache.read(CACHE_KEY)
        return missing_status unless cached.present?

        annotate_status(cached, source: "cache")
      end

      def check(force: false, refresh_if_stale: false)
        cached = Rails.cache.read(CACHE_KEY)
        if cached.present? && !force
          annotated = annotate_status(cached, source: "cache")
          return annotated unless refresh_if_stale && annotated[:stale]
        end

        perform_live_check
      end

      private

      def perform_live_check
        started_at = monotonic_started_at
        checked_at = Time.current

        microservice_required = local_microservice_required?
        microservice_enabled = local_microservice_enabled?
        microservice =
          if microservice_enabled
            Ai::LocalMicroserviceClient.new.test_connection!
          else
            {
              ok: !microservice_required,
              skipped: true,
              message: "Local AI microservice checks disabled by USE_LOCAL_AI_MICROSERVICE=false"
            }
          end
        ollama = Ai::OllamaClient.new.test_connection!

        microservice_ok = ActiveModel::Type::Boolean.new.cast(extract_ok_value(microservice))
        ollama_ok = ActiveModel::Type::Boolean.new.cast(extract_ok_value(ollama))
        ok = ollama_ok && (!microservice_required || microservice_ok)
        result = {
          ok: ok,
          checked_at: checked_at.iso8601(3),
          details: {
            microservice: microservice,
            ollama: ollama,
            policy: {
              microservice_enabled: microservice_enabled,
              microservice_required: microservice_required
            }
          }
        }

        Rails.cache.write(CACHE_KEY, result, expires_in: CACHE_TTL)
        track_healthcheck_metrics(result: result, started_at: started_at)

        annotate_status(result, source: "live")
      rescue StandardError => e
        failure = {
          ok: false,
          checked_at: Time.current.iso8601(3),
          error: e.message.to_s,
          error_class: e.class.name
        }

        Rails.cache.write(CACHE_KEY, failure, expires_in: FAILURE_CACHE_TTL)

        Ai::ApiUsageTracker.track_failure(
          provider: "local_ai_stack",
          operation: "health_check",
          category: "healthcheck",
          started_at: started_at,
          error: "#{e.class}: #{e.message}",
          metadata: failure
        )

        annotate_status(failure, source: "live")
      end

      def track_healthcheck_metrics(result:, started_at:)
        if ActiveModel::Type::Boolean.new.cast(result[:ok])
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
      end

      def extract_ok_value(payload)
        row = payload.is_a?(Hash) ? payload : {}
        row[:ok].nil? ? row["ok"] : row[:ok]
      end

      def local_microservice_enabled?
        ActiveModel::Type::Boolean.new.cast(ENV.fetch("USE_LOCAL_AI_MICROSERVICE", "false"))
      end

      def local_microservice_required?
        ActiveModel::Type::Boolean.new.cast(
          ENV.fetch("LOCAL_AI_MICROSERVICE_REQUIRED", "false")
        )
      end

      def annotate_status(payload, source:)
        row = payload.is_a?(Hash) ? payload.deep_symbolize_keys : {}
        checked_at_value = row[:checked_at].to_s
        checked_at_time = parse_timestamp(checked_at_value)

        row.merge(
          checked_at: checked_at_value.presence,
          stale: checked_at_time.nil? || checked_at_time < STALE_AFTER.ago,
          source: source.to_s
        )
      end

      def parse_timestamp(value)
        text = value.to_s.strip
        return nil if text.blank?

        Time.iso8601(text)
      rescue StandardError
        nil
      end

      def missing_status
        {
          ok: false,
          checked_at: nil,
          stale: true,
          source: "missing_cache",
          error: "No cached AI health status is available yet."
        }
      end

      def monotonic_started_at
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      rescue StandardError
        Time.current.to_f
      end
    end
  end
end
