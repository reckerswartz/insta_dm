# frozen_string_literal: true

module AiDashboard
  # Service for checking AI service health status
  # Extracted from AiDashboardController to follow Single Responsibility Principle
  class HealthChecker
    def initialize(force_refresh: false)
      @force_refresh = force_refresh
    end

    def call
      health = fetch_health_status
      enqueue_health_refresh_if_needed(health: health) unless @force_refresh

      format_health_response(health)
    end

    private

    def fetch_health_status
      if @force_refresh
        Ops::LocalAiHealth.check(force: true)
      else
        Ops::LocalAiHealth.status
      end
    end

    def format_health_response(health)
      checked_at = parse_health_checked_at(health[:checked_at])
      stale = ActiveModel::Type::Boolean.new.cast(health[:stale])

      if ActiveModel::Type::Boolean.new.cast(health[:ok])
        format_online_response(health, stale, checked_at)
      else
        format_offline_response(health, stale, checked_at)
      end
    end

    def format_online_response(health, stale, checked_at)
      service_map = build_service_map(health)
      details = extract_health_details(health)

      {
        status: "online",
        services: service_map,
        details: details,
        policy: details[:policy].is_a?(Hash) ? details[:policy] : {},
        stale: stale,
        source: health[:source].to_s,
        last_check: checked_at
      }
    end

    def format_offline_response(health, stale, checked_at)
      message = health[:error].presence || "Local AI stack unavailable"
      details = extract_health_details(health)

      {
        status: "offline",
        message: message,
        details: details,
        policy: details[:policy].is_a?(Hash) ? details[:policy] : {},
        stale: stale,
        source: health[:source].to_s,
        last_check: checked_at
      }
    end

    def build_service_map(health)
      service_map = health.dig(:details, :microservice, :services) || {}
      service_map = service_map.merge(
        "ollama" => Array(health.dig(:details, :ollama, :models)).any?
      )
      service_map
    end

    def extract_health_details(health)
      payload = health.is_a?(Hash) ? health[:details] || health["details"] : nil
      return {} unless payload.is_a?(Hash)

      payload.deep_symbolize_keys
    rescue StandardError
      {}
    end

    def enqueue_health_refresh_if_needed(health:)
      stale = ActiveModel::Type::Boolean.new.cast(health[:stale])
      unhealthy = !ActiveModel::Type::Boolean.new.cast(health[:ok])
      return unless stale || unhealthy

      throttle_key = "ops:local_ai_health:refresh_enqueued"
      return if Rails.cache.read(throttle_key)

      job = CheckAiMicroserviceHealthJob.perform_later
      Rails.cache.write(throttle_key, job.job_id, expires_in: 45.seconds)
    rescue StandardError
      nil
    end

    def parse_health_checked_at(value)
      text = value.to_s.strip
      return Time.current if text.blank?

      Time.iso8601(text)
    rescue StandardError
      Time.current
    end
  end
end
