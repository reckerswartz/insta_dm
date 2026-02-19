require "etc"

module Ops
  class ResourceGuard
    DEFAULT_MAX_LOAD_PER_CORE = ENV.fetch("AI_MAX_LOAD_PER_CORE", "1.20").to_f
    DEFAULT_MIN_AVAILABLE_MEMORY_MB = ENV.fetch("AI_MIN_AVAILABLE_MEMORY_MB", "700").to_i
    DEFAULT_MAX_QUEUE_DEPTH = ENV.fetch("AI_MAX_QUEUE_DEPTH", "220").to_i
    DEFAULT_RETRY_SECONDS = ENV.fetch("AI_RESOURCE_RETRY_SECONDS", "20").to_i

    class << self
      def allow_ai_task?(task:, queue_name:, critical: false)
        snapshot = snapshot(queue_name: queue_name)
        overloaded = overloaded?(snapshot: snapshot)

        if !overloaded || ActiveModel::Type::Boolean.new.cast(critical)
          return {
            allow: true,
            reason: nil,
            retry_in_seconds: nil,
            snapshot: snapshot,
            task: task.to_s
          }
        end

        {
          allow: false,
          reason: reason_for(snapshot: snapshot),
          retry_in_seconds: retry_seconds_for(snapshot: snapshot),
          snapshot: snapshot,
          task: task.to_s
        }
      rescue StandardError => e
        {
          allow: true,
          reason: "resource_guard_error:#{e.class}",
          retry_in_seconds: nil,
          snapshot: { error: e.message.to_s },
          task: task.to_s
        }
      end

      def snapshot(queue_name: nil)
        {
          queue_name: queue_name.to_s,
          queue_depth: queue_depth_for(queue_name: queue_name),
          load_average_1m: load_average_1m,
          load_per_core: load_per_core,
          cpu_cores: cpu_cores,
          available_memory_mb: available_memory_mb,
          checked_at: Time.current.iso8601(3)
        }
      end

      private

      def overloaded?(snapshot:)
        snapshot[:load_per_core].to_f > DEFAULT_MAX_LOAD_PER_CORE ||
          snapshot[:available_memory_mb].to_i < DEFAULT_MIN_AVAILABLE_MEMORY_MB ||
          snapshot[:queue_depth].to_i > DEFAULT_MAX_QUEUE_DEPTH
      end

      def reason_for(snapshot:)
        return "high_queue_depth" if snapshot[:queue_depth].to_i > DEFAULT_MAX_QUEUE_DEPTH
        return "high_cpu_load" if snapshot[:load_per_core].to_f > DEFAULT_MAX_LOAD_PER_CORE
        return "low_available_memory" if snapshot[:available_memory_mb].to_i < DEFAULT_MIN_AVAILABLE_MEMORY_MB

        "resource_pressure"
      end

      def retry_seconds_for(snapshot:)
        case reason_for(snapshot: snapshot)
        when "high_queue_depth"
          DEFAULT_RETRY_SECONDS
        when "high_cpu_load"
          DEFAULT_RETRY_SECONDS + 10
        when "low_available_memory"
          DEFAULT_RETRY_SECONDS + 20
        else
          DEFAULT_RETRY_SECONDS
        end
      end

      def queue_depth_for(queue_name:)
        return 0 if queue_name.to_s.blank?
        return 0 unless sidekiq_backend?

        require "sidekiq/api"

        Sidekiq::Queue.new(queue_name.to_s).size
      rescue StandardError
        0
      end

      def sidekiq_backend?
        Rails.application.config.active_job.queue_adapter.to_s == "sidekiq"
      rescue StandardError
        false
      end

      def load_average_1m
        File.read("/proc/loadavg").to_s.split.first.to_f
      rescue StandardError
        0.0
      end

      def cpu_cores
        value = Etc.nprocessors
        value.to_i.positive? ? value.to_i : 1
      rescue StandardError
        1
      end

      def load_per_core
        load_average_1m.to_f / cpu_cores.to_f
      rescue StandardError
        load_average_1m.to_f
      end

      def available_memory_mb
        line = File.readlines("/proc/meminfo").find { |row| row.start_with?("MemAvailable:") }
        return 0 unless line

        kb = line.split[1].to_i
        (kb / 1024.0).round
      rescue StandardError
        0
      end
    end
  end
end
