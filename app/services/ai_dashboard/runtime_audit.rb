# frozen_string_literal: true

module AiDashboard
  class RuntimeAudit
    LEGACY_QUEUE_KEY = "legacy_ai_default"
    SECONDARY_FACE_KEY = "face_analysis_secondary"

    def initialize(service_status:, queue_metrics:)
      @service_status = service_status.is_a?(Hash) ? service_status.deep_symbolize_keys : {}
      @queue_metrics = queue_metrics.is_a?(Hash) ? queue_metrics.deep_symbolize_keys : {}
      @queue_backend = @queue_metrics[:backend].to_s.presence || detect_queue_backend
    end

    def call
      metrics_by_key = queue_metrics_by_key
      concurrent_services = build_concurrent_services(metrics_by_key: metrics_by_key)
      architecture = architecture_snapshot

      {
        captured_at: Time.current.iso8601(3),
        queue_backend: @queue_backend,
        architecture: architecture,
        concurrent_services: concurrent_services,
        totals: totals(concurrent_services: concurrent_services),
        cleanup_candidates: cleanup_candidates(
          architecture: architecture,
          metrics_by_key: metrics_by_key,
          concurrent_services: concurrent_services
        )
      }
    rescue StandardError => e
      {
        captured_at: Time.current.iso8601(3),
        queue_backend: @queue_backend,
        architecture: {},
        concurrent_services: [],
        totals: {},
        cleanup_candidates: [
          {
            id: "runtime_audit_error",
            status: "audit_failed",
            title: "Runtime audit unavailable",
            evidence: "#{e.class}: #{e.message}".to_s.truncate(220),
            recommended_action: "Review application logs and retry the runtime audit."
          }
        ]
      }
    end

    private

    def build_concurrent_services(metrics_by_key:)
      Ops::AiServiceQueueRegistry.services.map do |service|
        metric = metrics_by_key[service.key.to_s] || {}
        queue_pending = metric[:queue_pending].to_i
        api_calls_24h = metric[:api_calls_24h].to_i
        failures_24h = metric[:recent_failures_24h].to_i

        {
          service_key: service.key.to_s,
          service_name: service.name.to_s,
          category: service.category.to_s,
          queue_name: service.queue_name.to_s,
          queue_pending: queue_pending,
          configured_concurrency: Ops::AiServiceQueueRegistry.concurrency_for(service: service).to_i,
          concurrency_env: service.concurrency_env.to_s,
          recent_failures_24h: failures_24h,
          api_calls_24h: api_calls_24h,
          api_failed_calls_24h: metric[:api_failed_calls_24h].to_i,
          api_total_tokens_24h: metric[:api_total_tokens_24h].to_i,
          sampled_job_classes: Array(metric[:sampled_job_classes]),
          job_class_count: service.normalized_job_classes.length,
          active: queue_pending.positive? || api_calls_24h.positive? || failures_24h.positive?
        }
      end
    end

    def architecture_snapshot
      details = @service_status[:details].is_a?(Hash) ? @service_status[:details].deep_symbolize_keys : {}
      microservice = details[:microservice].is_a?(Hash) ? details[:microservice] : {}
      ollama = details[:ollama].is_a?(Hash) ? details[:ollama] : {}
      policy = details[:policy].is_a?(Hash) ? details[:policy] : {}

      available_models = normalize_string_array(ollama[:models])
      configured_models = {
        base: Ai::ModelDefaults.base_model,
        fast: Ai::ModelDefaults.fast_model,
        quality: Ai::ModelDefaults.quality_model,
        comment: Ai::ModelDefaults.comment_model,
        vision: Ai::ModelDefaults.vision_model
      }.transform_values { |value| value.to_s.strip }

      {
        stack_status: @service_status[:status].to_s,
        microservice_ok: ActiveModel::Type::Boolean.new.cast(extract_ok(microservice)),
        microservice_enabled: ActiveModel::Type::Boolean.new.cast(policy[:microservice_enabled]),
        microservice_required: ActiveModel::Type::Boolean.new.cast(policy[:microservice_required]),
        microservice_services: normalize_service_map(microservice[:services]),
        ollama_ok: ActiveModel::Type::Boolean.new.cast(extract_ok(ollama)),
        ollama_available_models: available_models,
        configured_models: configured_models,
        unused_ollama_models: available_models - configured_models.values,
        lightweight_controls: {
          local_provider_lightweight_mode: env_boolean("LOCAL_PROVIDER_LIGHTWEIGHT_MODE", default: true),
          post_video_lightweight_mode: env_boolean("POST_VIDEO_LIGHTWEIGHT_MODE", default: true),
          skip_dynamic_vision_when_audio_present: env_boolean("POST_VIDEO_SKIP_DYNAMIC_VISION_WHEN_AUDIO_PRESENT", default: true),
          post_video_frame_sample_limit: env_integer("POST_VIDEO_VISION_FRAME_SAMPLE_LIMIT", default: 3),
          post_video_dynamic_keyframe_limit: env_integer("POST_VIDEO_DYNAMIC_KEYFRAME_LIMIT", default: 2)
        }
      }
    end

    def cleanup_candidates(architecture:, metrics_by_key:, concurrent_services:)
      rows = []
      rows << legacy_queue_candidate(metrics_by_key: metrics_by_key)
      rows << secondary_face_queue_candidate(metrics_by_key: metrics_by_key)
      rows << deprecated_queue_config_candidate
      rows << unused_models_candidate(architecture: architecture)
      rows.concat(idle_lane_candidates(concurrent_services: concurrent_services))
      rows.compact
    end

    def legacy_queue_candidate(metrics_by_key:)
      legacy_service = Ops::AiServiceQueueRegistry.service_for(LEGACY_QUEUE_KEY)
      return nil unless legacy_service

      metric = metrics_by_key[LEGACY_QUEUE_KEY] || {}
      pending = metric[:queue_pending].to_i
      api_calls = metric[:api_calls_24h].to_i

      safe_to_remove = pending.zero? && api_calls.zero?
      {
        id: LEGACY_QUEUE_KEY,
        status: safe_to_remove ? "safe_to_remove" : "keep_temporarily",
        title: "Legacy default AI queue lane",
        evidence: "queue=#{pending}, api_calls_24h=#{api_calls}",
        recommended_action: safe_to_remove ?
          "Remove `legacy_ai_default` from `Ops::AiServiceQueueRegistry::SERVICE_ROWS` and drop capsule `ai_legacy_lane`." :
          "Keep temporarily for backward-compatibility with older queued jobs."
      }
    end

    def secondary_face_queue_candidate(metrics_by_key:)
      metric = metrics_by_key[SECONDARY_FACE_KEY] || {}
      pending = metric[:queue_pending].to_i
      secondary_enabled = ActiveModel::Type::Boolean.new.cast(
        Ai::PostAnalysisPipelineState::DEFAULT_TASK_FLAGS["secondary_face_analysis"]
      )

      status =
        if !secondary_enabled && pending.zero?
          "safe_to_remove"
        elsif secondary_enabled
          "keep_tuned"
        else
          "review"
        end

      recommendation =
        if status == "safe_to_remove"
          "Remove `face_analysis_secondary` lane and queue `ai_face_secondary_queue`."
        elsif status == "keep_tuned"
          "Keep this lane for ambiguous-face retries, but keep concurrency at 1 unless backlog grows."
        else
          "Verify whether secondary face analysis is still needed before removing the lane."
        end

      {
        id: SECONDARY_FACE_KEY,
        status: status,
        title: "Secondary face analysis lane",
        evidence: "queue=#{pending}, default_secondary_face_analysis=#{secondary_enabled}",
        recommended_action: recommendation
      }
    end

    def deprecated_queue_config_candidate
      path = Rails.root.join("config/queue.yml")
      return nil unless File.exist?(path)

      {
        id: "deprecated_queue_yml",
        status: @queue_backend == "sidekiq" ? "safe_to_remove" : "review",
        title: "Deprecated `config/queue.yml` remains in repository",
        evidence: "backend=#{@queue_backend}",
        recommended_action: @queue_backend == "sidekiq" ?
          "Remove or heavily trim `config/queue.yml`; Sidekiq queue topology is controlled via `config/sidekiq.yml` and `Ops::AiServiceQueueRegistry`." :
          "Keep only if Solid Queue is still used in this environment."
      }
    end

    def unused_models_candidate(architecture:)
      unused_models = normalize_string_array(architecture[:unused_ollama_models])
      return nil if unused_models.empty?

      commands = unused_models.first(3).map { |name| "ollama rm #{name}" }

      {
        id: "unused_ollama_models",
        status: "safe_to_remove",
        title: "Installed Ollama models not referenced by current defaults",
        evidence: unused_models.join(", "),
        recommended_action: "Remove unused models to save RAM/disk. Example: #{commands.join(' ; ')}"
      }
    end

    def idle_lane_candidates(concurrent_services:)
      concurrent_services
        .select do |row|
          row[:configured_concurrency].to_i > 1 &&
            row[:queue_pending].to_i.zero? &&
            row[:api_calls_24h].to_i.zero? &&
            row[:recent_failures_24h].to_i.zero? &&
            row[:service_key].to_s != LEGACY_QUEUE_KEY
        end
        .first(4)
        .map do |row|
          {
            id: "idle_#{row[:service_key]}",
            status: "tune_concurrency",
            title: "Idle high-concurrency lane: #{row[:service_name]}",
            evidence: "queue=#{row[:queue_pending]}, api_calls_24h=#{row[:api_calls_24h]}, concurrency=#{row[:configured_concurrency]}",
            recommended_action: "Set `#{row[:concurrency_env]}` to `1` to reduce local contention."
          }
        end
    end

    def totals(concurrent_services:)
      total = concurrent_services.length
      active = concurrent_services.count { |row| ActiveModel::Type::Boolean.new.cast(row[:active]) }

      {
        total_lanes: total,
        active_lanes: active,
        idle_lanes: [total - active, 0].max
      }
    end

    def queue_metrics_by_key
      Array(@queue_metrics[:services]).each_with_object({}) do |row, map|
        payload = row.is_a?(Hash) ? row.deep_symbolize_keys : {}
        key = payload[:service_key].to_s
        next if key.blank?

        map[key] = payload
      end
    end

    def extract_ok(payload)
      return false unless payload.is_a?(Hash)
      return payload[:ok] unless payload[:ok].nil?

      payload["ok"]
    rescue StandardError
      false
    end

    def normalize_service_map(payload)
      return {} unless payload.is_a?(Hash)

      payload.transform_keys(&:to_s).transform_values { |value| ActiveModel::Type::Boolean.new.cast(value) }
    rescue StandardError
      {}
    end

    def normalize_string_array(values)
      Array(values).map(&:to_s).map(&:strip).reject(&:blank?).uniq
    end

    def env_boolean(key, default:)
      fallback = default ? "true" : "false"
      ActiveModel::Type::Boolean.new.cast(ENV.fetch(key.to_s, fallback))
    rescue StandardError
      default
    end

    def env_integer(key, default:)
      ENV.fetch(key.to_s, default).to_i
    rescue StandardError
      default.to_i
    end

    def detect_queue_backend
      Rails.application.config.active_job.queue_adapter.to_s
    rescue StandardError
      "unknown"
    end
  end
end
