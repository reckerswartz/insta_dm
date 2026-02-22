# frozen_string_literal: true

require "open3"
require "socket"

module AiDashboard
  class RuntimeAudit
    SECONDARY_FACE_KEY = "face_analysis_secondary"
    HOST_SERVICE_ROWS = [
      {
        key: "rails_web",
        service_name: "Rails Web",
        required: true,
        port: 3000,
        process_pattern: "puma",
        impact: "Serves authenticated UI and control actions."
      },
      {
        key: "sidekiq_worker",
        service_name: "Sidekiq Worker",
        required: true,
        process_pattern: "sidekiq",
        impact: "Runs post/story/background pipelines and retries."
      },
      {
        key: "redis",
        service_name: "Redis",
        required: true,
        port: 6379,
        process_pattern: "redis-server",
        impact: "Queue backend and short-lived cache coordination."
      },
      {
        key: "ollama",
        service_name: "Ollama",
        required: true,
        port: 11434,
        process_pattern: "ollama serve",
        impact: "Primary local LLM inference engine."
      },
      {
        key: "local_microservice",
        service_name: "Local AI Microservice",
        required: false,
        port: 8000,
        process_pattern: "ai_microservice/main.py",
        impact: "Optional CV/OCR/Whisper endpoints used by selected steps."
      }
    ].freeze

    def initialize(service_status:, queue_metrics:)
      @service_status = service_status.is_a?(Hash) ? service_status.deep_symbolize_keys : {}
      @queue_metrics = queue_metrics.is_a?(Hash) ? queue_metrics.deep_symbolize_keys : {}
      @queue_backend = @queue_metrics[:backend].to_s.presence || detect_queue_backend
    end

    def call
      metrics_by_key = queue_metrics_by_key
      queue_eta_by_queue = queue_estimates_by_queue_name
      architecture = architecture_snapshot
      host_services = build_host_services(architecture: architecture)
      concurrent_services = build_concurrent_services(
        metrics_by_key: metrics_by_key,
        queue_eta_by_queue: queue_eta_by_queue
      )

      {
        captured_at: Time.current.iso8601(3),
        queue_backend: @queue_backend,
        architecture: architecture,
        host_services: host_services,
        concurrent_services: concurrent_services,
        totals: totals(concurrent_services: concurrent_services, host_services: host_services),
        cleanup_candidates: cleanup_candidates(
          architecture: architecture,
          metrics_by_key: metrics_by_key,
          concurrent_services: concurrent_services,
          host_services: host_services
        )
      }
    rescue StandardError => e
      {
        captured_at: Time.current.iso8601(3),
        queue_backend: @queue_backend,
        architecture: {},
        host_services: [],
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

    def build_concurrent_services(metrics_by_key:, queue_eta_by_queue:)
      Ops::AiServiceQueueRegistry.services.map do |service|
        metric = metrics_by_key[service.key.to_s] || {}
        queue_eta = queue_eta_by_queue[service.queue_name.to_s] || {}
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
          eta_new_item_seconds: queue_eta[:estimated_new_item_total_seconds],
          eta_queue_drain_seconds: queue_eta[:estimated_queue_drain_seconds],
          eta_confidence: queue_eta[:confidence].to_s.presence || "low",
          eta_sample_size: queue_eta[:sample_size].to_i,
          data_impact: service.description.to_s,
          active: queue_pending.positive? || api_calls_24h.positive? || failures_24h.positive?
        }
      end
    end

    def build_host_services(architecture:)
      microservice_enabled = ActiveModel::Type::Boolean.new.cast(architecture[:microservice_enabled])
      microservice_required = ActiveModel::Type::Boolean.new.cast(architecture[:microservice_required])

      HOST_SERVICE_ROWS.map do |row|
        port = row[:port]
        process_pattern = row[:process_pattern].to_s
        process_count = process_pattern.present? ? process_count_for(pattern: process_pattern) : 0
        port_open = port.present? ? port_open?(port: port.to_i) : nil
        active = ActiveModel::Type::Boolean.new.cast(port_open) || process_count.positive?
        required =
          if row[:key].to_s == "local_microservice"
            microservice_enabled || microservice_required
          else
            ActiveModel::Type::Boolean.new.cast(row[:required])
          end

        {
          service_key: row[:key].to_s,
          service_name: row[:service_name].to_s,
          required: required,
          active: active,
          status: active ? "running" : (required ? "missing" : "optional_off"),
          port: port,
          port_open: port_open,
          process_pattern: process_pattern,
          process_count: process_count,
          impact: row[:impact].to_s
        }.compact
      end
    rescue StandardError
      []
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

    def cleanup_candidates(architecture:, metrics_by_key:, concurrent_services:, host_services:)
      rows = []
      rows << secondary_face_queue_candidate(metrics_by_key: metrics_by_key)
      rows << deprecated_queue_config_candidate
      rows << unused_models_candidate(architecture: architecture)
      rows.concat(host_service_candidates(host_services: host_services, architecture: architecture))
      rows.concat(idle_lane_candidates(concurrent_services: concurrent_services))
      rows.concat(high_failure_lane_candidates(concurrent_services: concurrent_services))
      rows.compact
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

    def host_service_candidates(host_services:, architecture:)
      rows = []
      microservice = Array(host_services).find { |row| row[:service_key].to_s == "local_microservice" }
      if microservice.is_a?(Hash)
        microservice_enabled = ActiveModel::Type::Boolean.new.cast(architecture[:microservice_enabled])
        if !microservice_enabled && ActiveModel::Type::Boolean.new.cast(microservice[:active])
          rows << {
            id: "orphan_local_microservice",
            status: "safe_to_remove",
            title: "Local AI microservice is running but disabled in policy",
            evidence: "active=#{microservice[:active]}, required=#{microservice[:required]}, port_open=#{microservice[:port_open]}",
            recommended_action: "Stop microservice process to free CPU/RAM, or set `USE_LOCAL_AI_MICROSERVICE=true` if required."
          }
        elsif microservice_enabled && !ActiveModel::Type::Boolean.new.cast(microservice[:active])
          rows << {
            id: "missing_local_microservice",
            status: "review",
            title: "Local AI microservice is enabled but not running",
            evidence: "active=#{microservice[:active]}, required=#{microservice[:required]}, port_open=#{microservice[:port_open]}",
            recommended_action: "Start microservice (`bin/local_ai_services start`) or disable it with `USE_LOCAL_AI_MICROSERVICE=false`."
          }
        end
      end

      sidekiq = Array(host_services).find { |row| row[:service_key].to_s == "sidekiq_worker" }
      if sidekiq.is_a?(Hash) && sidekiq[:process_count].to_i > 1
        rows << {
          id: "multiple_sidekiq_processes",
          status: "tune_concurrency",
          title: "Multiple Sidekiq worker processes detected",
          evidence: "process_count=#{sidekiq[:process_count]}",
          recommended_action: "Keep one worker process for local machines unless you intentionally run a multi-worker setup."
        }
      end

      Array(host_services).each do |service|
        row = service.is_a?(Hash) ? service : {}
        service_key = row[:service_key].to_s
        next if service_key == "local_microservice"
        next unless ActiveModel::Type::Boolean.new.cast(row[:required])
        next if ActiveModel::Type::Boolean.new.cast(row[:active])

        rows << {
          id: "missing_#{service_key}",
          status: "review",
          title: "Required service offline: #{row[:service_name]}",
          evidence: "port_open=#{row[:port_open]}, process_count=#{row[:process_count]}",
          recommended_action: "Start #{row[:service_name]} or disable features that depend on it."
        }
      end

      rows
    end

    def idle_lane_candidates(concurrent_services:)
      concurrent_services
        .select do |row|
          row[:configured_concurrency].to_i > 1 &&
            row[:queue_pending].to_i.zero? &&
            row[:api_calls_24h].to_i.zero? &&
            row[:recent_failures_24h].to_i.zero? &&
            row[:service_key].to_s != SECONDARY_FACE_KEY
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

    def high_failure_lane_candidates(concurrent_services:)
      concurrent_services
        .select { |row| row[:recent_failures_24h].to_i >= 8 }
        .sort_by { |row| -row[:recent_failures_24h].to_i }
        .first(4)
        .map do |row|
          {
            id: "failure_hotspot_#{row[:service_key]}",
            status: "tune_concurrency",
            title: "Failure hotspot: #{row[:service_name]}",
            evidence: "failures_24h=#{row[:recent_failures_24h]}, queue=#{row[:queue_pending]}, concurrency=#{row[:configured_concurrency]}",
            recommended_action: "Reduce `#{row[:concurrency_env]}` to `1`, keep lightweight mode on, and investigate recurring errors before scaling."
          }
        end
    end

    def totals(concurrent_services:, host_services:)
      total = concurrent_services.length
      active = concurrent_services.count { |row| ActiveModel::Type::Boolean.new.cast(row[:active]) }
      active_drain_seconds = concurrent_services
        .select { |row| ActiveModel::Type::Boolean.new.cast(row[:active]) }
        .sum { |row| row[:eta_queue_drain_seconds].to_f }
      host_total = Array(host_services).length
      host_active = Array(host_services).count { |row| ActiveModel::Type::Boolean.new.cast(row[:active]) }
      host_required_missing = Array(host_services).count do |row|
        ActiveModel::Type::Boolean.new.cast(row[:required]) && !ActiveModel::Type::Boolean.new.cast(row[:active])
      end

      {
        total_lanes: total,
        active_lanes: active,
        idle_lanes: [ total - active, 0 ].max,
        active_lane_drain_eta_seconds: active_drain_seconds.round(1),
        host_services_total: host_total,
        host_services_active: host_active,
        host_services_required_missing: host_required_missing
      }
    end

    def queue_estimates_by_queue_name
      snapshot = Ops::QueueProcessingEstimator.snapshot(
        backend: @queue_backend,
        queue_names: Ops::AiServiceQueueRegistry.ai_queue_names
      )
      Array(snapshot[:estimates]).each_with_object({}) do |row, map|
        payload = row.is_a?(Hash) ? row.deep_symbolize_keys : {}
        queue_name = payload[:queue_name].to_s
        next if queue_name.blank?

        map[queue_name] = payload
      end
    rescue StandardError
      {}
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

    def port_open?(port:)
      Socket.tcp("127.0.0.1", port.to_i, connect_timeout: 0.25) do |socket|
        socket.close
      end
      true
    rescue StandardError
      false
    end

    def process_count_for(pattern:)
      needle = pattern.to_s.strip
      return 0 if needle.blank?

      stdout, _status = Open3.capture2("ps", "-eo", "args")
      stdout.to_s.each_line.count do |line|
        row = line.to_s
        row.include?(needle) && !row.include?("ps -eo args")
      end
    rescue StandardError
      0
    end

    def detect_queue_backend
      Rails.application.config.active_job.queue_adapter.to_s
    rescue StandardError
      "unknown"
    end
  end
end
