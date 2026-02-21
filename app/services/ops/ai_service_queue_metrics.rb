module Ops
  class AiServiceQueueMetrics
    API_WINDOW = 24.hours
    FAILURE_WINDOW = 24.hours
    MAX_QUEUE_JOB_SAMPLE = ENV.fetch("AI_SERVICE_QUEUE_METRICS_MAX_QUEUE_JOB_SAMPLE", 200).to_i.clamp(25, 2_000)

    class << self
      def snapshot(account_id: nil, backend: nil)
        queue_backend = backend.to_s.presence || detect_backend
        queue_sizes = queue_sizes_by_name(backend: queue_backend)
        recent_failures_by_queue = recent_failures_by_queue(account_id: account_id)
        api_usage_by_service = api_usage_by_service(account_id: account_id)
        queue_job_samples = queue_job_samples_by_service(backend: queue_backend)

        services = Ops::AiServiceQueueRegistry.services.map do |service|
          api_usage = api_usage_by_service[service.key.to_s] || empty_api_usage_bucket
          sample = queue_job_samples[service.key.to_s] || {}
          queue_pending = queue_sizes[service.queue_name.to_s].to_i

          {
            service_key: service.key.to_s,
            service_name: service.name.to_s,
            category: service.category.to_s,
            queue_name: service.queue_name.to_s,
            queue_pending: queue_pending,
            recent_failures_24h: recent_failures_by_queue[service.queue_name.to_s].to_i,
            api_calls_24h: api_usage[:total].to_i,
            api_failed_calls_24h: api_usage[:failed].to_i,
            api_total_tokens_24h: api_usage[:total_tokens].to_i,
            api_avg_latency_ms_24h: average_latency_ms_for(api_usage),
            top_providers_24h: top_counts(api_usage[:providers]),
            top_operations_24h: top_counts(api_usage[:operations]),
            sampled_job_classes: top_counts(sample)
          }
        end

        {
          backend: queue_backend,
          captured_at: Time.current.iso8601(3),
          queue_pending_total: services.sum { |row| row[:queue_pending].to_i },
          api_calls_total_24h: services.sum { |row| row[:api_calls_24h].to_i },
          api_failed_calls_total_24h: services.sum { |row| row[:api_failed_calls_24h].to_i },
          services: services.sort_by { |row| [ -row[:queue_pending].to_i, -row[:api_calls_24h].to_i, row[:service_name].to_s ] },
          unmapped_ai_queue_jobs: top_counts(queue_job_samples["__unmapped__"] || {})
        }
      rescue StandardError
        {
          backend: backend.to_s.presence || detect_backend,
          captured_at: Time.current.iso8601(3),
          queue_pending_total: 0,
          api_calls_total_24h: 0,
          api_failed_calls_total_24h: 0,
          services: [],
          unmapped_ai_queue_jobs: []
        }
      end

      private

      def detect_backend
        Rails.application.config.active_job.queue_adapter.to_s
      rescue StandardError
        "unknown"
      end

      def queue_sizes_by_name(backend:)
        return sidekiq_queue_sizes if backend.to_s == "sidekiq"
        return solid_queue_sizes if backend.to_s == "solid_queue"

        {}
      end

      def sidekiq_queue_sizes
        require "sidekiq/api"

        Sidekiq::Queue.all.each_with_object({}) do |queue, map|
          map[queue.name.to_s] = queue.size.to_i
        end
      rescue StandardError
        {}
      end

      def solid_queue_sizes
        rows = Hash.new(0)
        merge_solid_queue_counts!(rows, SolidQueue::ReadyExecution)
        merge_solid_queue_counts!(rows, SolidQueue::ScheduledExecution)
        merge_solid_queue_counts!(rows, SolidQueue::ClaimedExecution)
        merge_solid_queue_counts!(rows, SolidQueue::BlockedExecution)
        rows
      rescue StandardError
        {}
      end

      def merge_solid_queue_counts!(rows, execution_class)
        execution_class
          .joins(:job)
          .group("solid_queue_jobs.queue_name")
          .count
          .each do |queue_name, count|
            rows[queue_name.to_s] += count.to_i
          end
      rescue StandardError
        nil
      end

      def recent_failures_by_queue(account_id:)
        scope = BackgroundJobFailure.where("occurred_at >= ?", FAILURE_WINDOW.ago)
        scope = scope.where(instagram_account_id: account_id.to_i) if account_id.present?
        scope.group(:queue_name).count.transform_keys(&:to_s)
      rescue StandardError
        {}
      end

      def api_usage_by_service(account_id:)
        scope = AiApiCall.where(occurred_at: API_WINDOW.ago..Time.current)
        scope = scope.where(instagram_account_id: account_id.to_i) if account_id.present?

        rows = Hash.new { |hash, key| hash[key] = empty_api_usage_bucket.dup }
        scope.find_each(batch_size: 500) do |call|
          service = ai_service_for_call(call)
          next unless service

          bucket = rows[service.key.to_s]
          bucket[:total] += 1
          bucket[:failed] += 1 if call.status.to_s == "failed"
          latency = call.latency_ms.to_i
          if latency.positive?
            bucket[:latency_sum] += latency
            bucket[:latency_count] += 1
          end
          bucket[:total_tokens] += call.total_tokens.to_i
          bucket[:providers][call.provider.to_s] += 1 if call.provider.to_s.present?
          bucket[:operations][call.operation.to_s] += 1 if call.operation.to_s.present?
        end

        rows
      rescue StandardError
        {}
      end

      def ai_service_for_call(call)
        metadata = call.metadata.is_a?(Hash) ? call.metadata : {}
        queue_name = metadata["queue_name"].to_s
        job_class = metadata["job_class"].to_s
        Ops::AiServiceQueueRegistry.service_for_queue(queue_name) ||
          Ops::AiServiceQueueRegistry.service_for_job_class(job_class)
      rescue StandardError
        nil
      end

      def queue_job_samples_by_service(backend:)
        return {} unless backend.to_s == "sidekiq"

        require "sidekiq/api"
        rows = Hash.new { |hash, key| hash[key] = Hash.new(0) }
        ai_queue_names = Ops::AiServiceQueueRegistry.ai_queue_names

        Sidekiq::Queue.all.each do |queue|
          queue_name = queue.name.to_s
          next unless ai_queue_names.include?(queue_name)

          queue.first(MAX_QUEUE_JOB_SAMPLE).each do |job|
            job_class = job.klass.to_s
            service = Ops::AiServiceQueueRegistry.service_for_job_class(job_class) ||
              Ops::AiServiceQueueRegistry.service_for_queue(queue_name)
            if service
              rows[service.key.to_s][job_class] += 1
            else
              rows["__unmapped__"]["#{queue_name}:#{job_class}"] += 1
            end
          end
        end

        rows
      rescue StandardError
        {}
      end

      def empty_api_usage_bucket
        {
          total: 0,
          failed: 0,
          latency_sum: 0,
          latency_count: 0,
          total_tokens: 0,
          providers: Hash.new(0),
          operations: Hash.new(0)
        }
      end

      def average_latency_ms_for(bucket)
        count = bucket[:latency_count].to_i
        return nil if count <= 0

        (bucket[:latency_sum].to_f / count.to_f).round(1)
      rescue StandardError
        nil
      end

      def top_counts(hash, limit: 3)
        return [] unless hash.is_a?(Hash)

        hash
          .sort_by { |(_key, count)| -count.to_i }
          .first(limit)
          .map do |(key, count)|
            { key: key.to_s, count: count.to_i }
          end
      rescue StandardError
        []
      end
    end
  end
end
