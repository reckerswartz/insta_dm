# frozen_string_literal: true

module AiDashboard
  # Service for checking AI service health status.
  #
  # Phase 10 retargets this off the deleted Ops::LocalAiHealth (Ollama)
  # shim and onto the NVIDIA Build provider that is the hot path after
  # the Phase 4 migration. "Online" means at least one nvidia text role
  # is enabled with a credential, and `list_models!` reaches the API
  # when force_refresh is set.
  class HealthChecker
    CACHE_KEY = "ai_dashboard:nvidia_health:v1".freeze
    CACHE_TTL = 5.minutes
    STALE_AFTER = 4.minutes

    def initialize(force_refresh: false)
      @force_refresh = force_refresh
    end

    def call
      payload = @force_refresh ? perform_live_check : read_cache_or_live

      checked_at = parse_timestamp(payload[:checked_at])
      stale = checked_at.nil? || checked_at < STALE_AFTER.ago

      if ActiveModel::Type::Boolean.new.cast(payload[:ok])
        build_online_response(payload: payload, stale: stale, checked_at: checked_at)
      else
        build_offline_response(payload: payload, stale: stale, checked_at: checked_at)
      end
    end

    private

    def read_cache_or_live
      cached = Rails.cache.read(CACHE_KEY)
      return cached if cached.is_a?(Hash) && cached[:checked_at].present?

      perform_live_check
    end

    def perform_live_check
      ok = Ai::ChatClientFactory.nvidia_available?

      payload =
        if ok
          probe_nvidia_api
        else
          {
            ok: false,
            checked_at: Time.current.iso8601(3),
            source: "live",
            error: "No NVIDIA role is enabled with a credential. Configure one in Admin > AI Providers."
          }
        end

      Rails.cache.write(CACHE_KEY, payload, expires_in: CACHE_TTL) if payload[:ok]
      payload
    end

    def probe_nvidia_api
      setting = AiProviderSetting.for_provider("nvidia").where(enabled: true).where.not(api_key: [nil, ""]).first
      setting ||= AiProviderSetting.for_provider("nvidia").where(enabled: true).first

      return cache_eligible_offline("NVIDIA row unavailable") if setting.nil?

      client = Ai::NvidiaClient.new(setting: setting)
      response = client.list_models!
      models = Array(response["data"]).map { |row| row["id"].to_s }.reject(&:blank?)

      {
        ok: true,
        checked_at: Time.current.iso8601(3),
        source: "live",
        services: { "nvidia" => true },
        details: {
          nvidia: {
            ok: true,
            models: models,
            default_model: setting.effective_model
          }
        }
      }
    rescue Ai::NvidiaClient::Error => e
      cache_eligible_offline("NVIDIA API unreachable: #{e.message}")
    rescue StandardError => e
      cache_eligible_offline("Unexpected error: #{e.class}: #{e.message}")
    end

    def cache_eligible_offline(error_message)
      {
        ok: false,
        checked_at: Time.current.iso8601(3),
        source: "live",
        error: error_message,
        services: { "nvidia" => false }
      }
    end

    def build_online_response(payload:, stale:, checked_at:)
      details = payload[:details].is_a?(Hash) ? payload[:details] : {}
      services = payload[:services].is_a?(Hash) ? payload[:services] : { "nvidia" => true }

      {
        status: "online",
        services: services,
        details: details,
        policy: { execution_mode: "nvidia_build" },
        stale: stale,
        source: payload[:source].to_s,
        last_check: checked_at || Time.current
      }
    end

    def build_offline_response(payload:, stale:, checked_at:)
      message = payload[:error].to_s.presence || "NVIDIA provider unavailable"

      {
        status: "offline",
        message: message,
        services: payload[:services].is_a?(Hash) ? payload[:services] : { "nvidia" => false },
        details: payload[:details].is_a?(Hash) ? payload[:details] : {},
        policy: { execution_mode: "nvidia_build" },
        stale: stale,
        source: payload[:source].to_s,
        last_check: checked_at || Time.current
      }
    end

    def parse_timestamp(value)
      text = value.to_s.strip
      return nil if text.blank?

      Time.iso8601(text)
    rescue StandardError
      nil
    end
  end
end
