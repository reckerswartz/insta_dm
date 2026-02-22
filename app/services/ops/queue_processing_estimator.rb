module Ops
  class QueueProcessingEstimator
    LOOKBACK_WINDOW_HOURS = ENV.fetch("QUEUE_ESTIMATOR_LOOKBACK_HOURS", 24).to_i.clamp(1, 168)
    MAX_SAMPLE_SIZE = ENV.fetch("QUEUE_ESTIMATOR_MAX_SAMPLE_SIZE", 500).to_i.clamp(50, 5_000)
    MIN_SAMPLE_SIZE = ENV.fetch("QUEUE_ESTIMATOR_MIN_SAMPLE_SIZE", 8).to_i.clamp(3, 200)
    DEFAULT_PER_ITEM_MS = ENV.fetch("QUEUE_ESTIMATOR_DEFAULT_PER_ITEM_MS", 8_000).to_i.clamp(500, 120_000)
    CACHE_TTL_SECONDS = ENV.fetch("QUEUE_ESTIMATOR_CACHE_TTL_SECONDS", 15).to_i.clamp(0, 300)
    CACHE_VERSION = "v1".freeze

    class << self
      def snapshot(backend: nil, queue_names: nil, use_cache: true)
        cache_key = cache_key_for(backend: backend, queue_names: queue_names)
        if use_cache && cache_key
          return Rails.cache.fetch(cache_key, expires_in: CACHE_TTL_SECONDS.seconds) do
            build_snapshot(backend: backend, queue_names: queue_names)
          end
        end

        build_snapshot(backend: backend, queue_names: queue_names)
      end

      def estimate_for_queue(queue_name:, backend: nil, use_cache: true)
        queue = queue_name.to_s.strip
        return nil if queue.blank?

        snapshot_payload = snapshot(
          backend: backend,
          queue_names: [ queue ],
          use_cache: use_cache
        )
        Array(snapshot_payload[:estimates]).find { |row| row[:queue_name].to_s == queue }
      rescue StandardError
        nil
      end

      private

      def build_snapshot(backend:, queue_names:)
        adapter = backend.to_s.presence || detect_backend
        return empty_snapshot(backend: adapter) unless adapter == "sidekiq"

        require "sidekiq/api"

        queues = Sidekiq::Queue.all
        queue_rows = queues.map { |queue| queue_row(queue) }
        selected_names = normalize_queue_names(queue_rows: queue_rows, queue_names: queue_names)
        concurrency_map = queue_concurrency_map
        estimates = selected_names.map do |queue_name|
          queue_row = queue_rows.find { |row| row[:queue_name] == queue_name } || { queue_name: queue_name, queue_size: 0, queue_latency_seconds: 0.0 }
          estimate_queue_timing_row(
            queue_name: queue_name,
            queue_size: queue_row[:queue_size].to_i,
            queue_latency_seconds: queue_row[:queue_latency_seconds].to_f,
            estimated_concurrency: concurrency_map[queue_name].to_f
          )
        end

        {
          backend: adapter,
          captured_at: Time.current.iso8601(3),
          lookback_window_hours: LOOKBACK_WINDOW_HOURS,
          queue_count: selected_names.length,
          queued_items_total: estimates.sum { |row| row[:queue_size].to_i },
          estimates: estimates.sort_by { |row| [ -row[:queue_size].to_i, -row[:estimated_queue_drain_seconds].to_i, row[:queue_name].to_s ] }
        }
      rescue StandardError
        empty_snapshot(backend: adapter)
      end

      def estimate_queue_timing_row(queue_name:, queue_size:, queue_latency_seconds:, estimated_concurrency:)
        metrics_scope = completed_metrics_scope(queue_name: queue_name)
        processing_samples = metrics_scope
          .where.not(processing_duration_ms: nil)
          .order(recorded_at: :desc)
          .limit(MAX_SAMPLE_SIZE)
          .pluck(:processing_duration_ms)
          .map(&:to_i)
          .select(&:positive?)
        queue_wait_samples = metrics_scope
          .where.not(queue_wait_ms: nil)
          .order(recorded_at: :desc)
          .limit(MAX_SAMPLE_SIZE)
          .pluck(:queue_wait_ms)
          .map(&:to_i)
          .select(&:positive?)

        sample_size = processing_samples.length
        throughput_last_hour = metrics_scope.where("recorded_at >= ?", 1.hour.ago).count.to_i
        effective_concurrency = [ estimated_concurrency.to_f, 1.0 ].max

        median_processing_ms = percentile_ms(samples: processing_samples, percentile: 0.5)
        p90_processing_ms = percentile_ms(samples: processing_samples, percentile: 0.9)
        median_queue_wait_ms = percentile_ms(samples: queue_wait_samples, percentile: 0.5)
        per_item_ms = median_processing_ms || fallback_per_item_ms(throughput_last_hour: throughput_last_hour)
        per_item_ms = DEFAULT_PER_ITEM_MS if per_item_ms.to_i <= 0

        backlog_items = [ queue_size.to_i - 1, 0 ].max
        estimated_wait_ms = ((backlog_items.to_f / effective_concurrency) * per_item_ms.to_f).round
        estimated_total_ms = estimated_wait_ms + per_item_ms.to_i
        estimated_drain_ms = ((queue_size.to_f / effective_concurrency) * per_item_ms.to_f).round

        confidence = confidence_for(sample_size: sample_size, throughput_last_hour: throughput_last_hour)

        {
          queue_name: queue_name.to_s,
          queue_size: queue_size.to_i,
          queue_latency_seconds: queue_latency_seconds.to_f.round(2),
          estimated_concurrency: effective_concurrency.round(2),
          sample_size: sample_size,
          completed_last_hour: throughput_last_hour,
          median_processing_ms: median_processing_ms,
          p90_processing_ms: p90_processing_ms,
          median_queue_wait_ms: median_queue_wait_ms,
          estimated_new_item_wait_seconds: (estimated_wait_ms / 1000.0).round(1),
          estimated_new_item_total_seconds: (estimated_total_ms / 1000.0).round(1),
          estimated_queue_drain_seconds: (estimated_drain_ms / 1000.0).round(1),
          confidence: confidence
        }
      rescue StandardError
        {
          queue_name: queue_name.to_s,
          queue_size: queue_size.to_i,
          queue_latency_seconds: queue_latency_seconds.to_f.round(2),
          estimated_concurrency: [ estimated_concurrency.to_f, 1.0 ].max.round(2),
          sample_size: 0,
          completed_last_hour: 0,
          median_processing_ms: nil,
          p90_processing_ms: nil,
          median_queue_wait_ms: nil,
          estimated_new_item_wait_seconds: (queue_size.to_i * (DEFAULT_PER_ITEM_MS / 1000.0)).round(1),
          estimated_new_item_total_seconds: ((queue_size.to_i + 1) * (DEFAULT_PER_ITEM_MS / 1000.0)).round(1),
          estimated_queue_drain_seconds: (queue_size.to_i * (DEFAULT_PER_ITEM_MS / 1000.0)).round(1),
          confidence: "low"
        }
      end

      def normalize_queue_names(queue_rows:, queue_names:)
        provided = Array(queue_names).map(&:to_s).map(&:strip).reject(&:blank?).uniq
        return provided if provided.any?

        names_from_sizes = Array(queue_rows).map { |row| row[:queue_name].to_s }.select(&:present?)
        names_from_metrics = BackgroundJobExecutionMetric.completed
          .where("recorded_at >= ?", LOOKBACK_WINDOW_HOURS.hours.ago)
          .distinct
          .limit(200)
          .pluck(:queue_name)
          .map(&:to_s)

        (names_from_sizes + names_from_metrics).map(&:to_s).map(&:strip).reject(&:blank?).uniq
      rescue StandardError
        []
      end

      def queue_row(queue)
        {
          queue_name: queue.name.to_s,
          queue_size: queue.size.to_i,
          queue_latency_seconds: queue.latency.to_f
        }
      rescue StandardError
        {
          queue_name: queue&.name.to_s,
          queue_size: 0,
          queue_latency_seconds: 0.0
        }
      end

      def queue_concurrency_map
        require "sidekiq/api"

        map = Hash.new(0.0)
        Sidekiq::ProcessSet.new.each do |process|
          queues = Array(process["queues"]).map(&:to_s).reject(&:blank?)
          next if queues.empty?

          concurrency = process["concurrency"].to_f
          next if concurrency <= 0.0

          share = concurrency / queues.length.to_f
          queues.each do |queue_name|
            map[queue_name] += share
          end
        end

        map.transform_values { |value| value.round(2) }
      rescue StandardError
        {}
      end

      def completed_metrics_scope(queue_name:)
        BackgroundJobExecutionMetric.completed
          .where(queue_name: queue_name.to_s)
          .where("recorded_at >= ?", LOOKBACK_WINDOW_HOURS.hours.ago)
      end

      def percentile_ms(samples:, percentile:)
        rows = Array(samples).map(&:to_i).select(&:positive?)
        return nil if rows.empty?

        sorted = rows.sort
        index = ((sorted.length - 1) * percentile.to_f).round
        sorted[index]
      rescue StandardError
        nil
      end

      def fallback_per_item_ms(throughput_last_hour:)
        throughput = throughput_last_hour.to_i
        return nil if throughput <= 0

        (3600_000.0 / throughput.to_f).round
      rescue StandardError
        nil
      end

      def confidence_for(sample_size:, throughput_last_hour:)
        size = sample_size.to_i
        throughput = throughput_last_hour.to_i
        return "high" if size >= 60 && throughput >= 12
        return "medium" if size >= MIN_SAMPLE_SIZE && throughput >= 3

        "low"
      rescue StandardError
        "low"
      end

      def detect_backend
        Rails.application.config.active_job.queue_adapter.to_s
      rescue StandardError
        "unknown"
      end

      def empty_snapshot(backend:)
        {
          backend: backend.to_s.presence || "unknown",
          captured_at: Time.current.iso8601(3),
          lookback_window_hours: LOOKBACK_WINDOW_HOURS,
          queue_count: 0,
          queued_items_total: 0,
          estimates: []
        }
      end

      def cache_key_for(backend:, queue_names:)
        return nil unless CACHE_TTL_SECONDS.positive?
        return nil unless defined?(Rails) && Rails.respond_to?(:cache) && Rails.cache

        adapter = backend.to_s.presence || detect_backend
        normalized_queue_names = Array(queue_names).map(&:to_s).map(&:strip).reject(&:blank?).uniq.sort
        queues_key = normalized_queue_names.join(",")

        "ops:queue_processing_estimator:#{CACHE_VERSION}:#{adapter}:#{LOOKBACK_WINDOW_HOURS}:#{MAX_SAMPLE_SIZE}:#{queues_key}"
      rescue StandardError
        nil
      end
    end
  end
end
