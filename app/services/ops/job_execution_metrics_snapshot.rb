module Ops
  class JobExecutionMetricsSnapshot
    DEFAULT_WINDOW_HOURS = ENV.fetch("JOB_EXECUTION_METRICS_WINDOW_HOURS", 24).to_i.clamp(1, 168)
    DEFAULT_QUEUE_LIMIT = ENV.fetch("JOB_EXECUTION_METRICS_QUEUE_LIMIT", 20).to_i.clamp(1, 100)
    MAX_SAMPLE_SIZE = ENV.fetch("JOB_EXECUTION_METRICS_MAX_SAMPLE_SIZE", 400).to_i.clamp(50, 5_000)
    CACHE_TTL_SECONDS = ENV.fetch("JOB_EXECUTION_METRICS_CACHE_TTL_SECONDS", 20).to_i.clamp(0, 300)
    CACHE_VERSION = "v1".freeze

    class << self
      def snapshot(window_hours: DEFAULT_WINDOW_HOURS, queue_limit: DEFAULT_QUEUE_LIMIT, account_id: nil, use_cache: true)
        window = window_hours.to_i.clamp(1, 168)
        limit = queue_limit.to_i.clamp(1, 100)
        cache_key = cache_key_for(window: window, limit: limit, account_id: account_id)

        if use_cache && cache_key
          return Rails.cache.fetch(cache_key, expires_in: CACHE_TTL_SECONDS.seconds) do
            build_snapshot(window_hours: window, queue_limit: limit, account_id: account_id)
          end
        end

        build_snapshot(window_hours: window, queue_limit: limit, account_id: account_id)
      end

      private

      def build_snapshot(window_hours:, queue_limit:, account_id:)
        scope = metrics_scope(window_hours: window_hours, account_id: account_id)
        completed_scope = scope.completed
        failed_scope = scope.failed

        {
          captured_at: Time.current.iso8601(3),
          window_hours: window_hours.to_i,
          account_id: account_id.to_i.positive? ? account_id.to_i : nil,
          total_rows: scope.count.to_i,
          completed_rows: completed_scope.count.to_i,
          failed_rows: failed_scope.count.to_i,
          avg_processing_ms: average_ms(scope: completed_scope, column: :processing_duration_ms),
          avg_queue_wait_ms: average_ms(scope: completed_scope, column: :queue_wait_ms),
          avg_total_ms: average_ms(scope: completed_scope, column: :total_time_ms),
          queues: queue_rows(scope: scope, queue_limit: queue_limit)
        }
      rescue StandardError
        empty_snapshot(window_hours: window_hours, account_id: account_id)
      end

      def queue_rows(scope:, queue_limit:)
        top_queue_names = scope
          .group(:queue_name)
          .count
          .sort_by { |_queue_name, count| -count.to_i }
          .first(queue_limit.to_i)
          .map(&:first)
          .map(&:to_s)
          .reject(&:blank?)

        top_queue_names.map do |queue_name|
          queue_scope = scope.where(queue_name: queue_name)
          completed_scope = queue_scope.completed
          processing_samples = completed_scope
            .where.not(processing_duration_ms: nil)
            .order(recorded_at: :desc)
            .limit(MAX_SAMPLE_SIZE)
            .pluck(:processing_duration_ms)
          wait_samples = completed_scope
            .where.not(queue_wait_ms: nil)
            .order(recorded_at: :desc)
            .limit(MAX_SAMPLE_SIZE)
            .pluck(:queue_wait_ms)

          {
            queue_name: queue_name,
            total_rows: queue_scope.count.to_i,
            completed_rows: completed_scope.count.to_i,
            failed_rows: queue_scope.failed.count.to_i,
            sample_size: processing_samples.length,
            median_processing_ms: percentile_ms(samples: processing_samples, percentile: 0.5),
            p90_processing_ms: percentile_ms(samples: processing_samples, percentile: 0.9),
            median_queue_wait_ms: percentile_ms(samples: wait_samples, percentile: 0.5),
            avg_total_ms: average_ms(scope: completed_scope, column: :total_time_ms),
            last_recorded_at: queue_scope.maximum(:recorded_at)&.iso8601(3)
          }
        end
      rescue StandardError
        []
      end

      def average_ms(scope:, column:)
        scope.where.not(column => nil).average(column)&.round(1)
      rescue StandardError
        nil
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

      def metrics_scope(window_hours:, account_id:)
        scope = BackgroundJobExecutionMetric.within(window_hours.hours.ago..Time.current)
        scope = scope.where(instagram_account_id: account_id.to_i) if account_id.to_i.positive?
        scope
      end

      def empty_snapshot(window_hours:, account_id:)
        {
          captured_at: Time.current.iso8601(3),
          window_hours: window_hours.to_i,
          account_id: account_id.to_i.positive? ? account_id.to_i : nil,
          total_rows: 0,
          completed_rows: 0,
          failed_rows: 0,
          avg_processing_ms: nil,
          avg_queue_wait_ms: nil,
          avg_total_ms: nil,
          queues: []
        }
      end

      def cache_key_for(window:, limit:, account_id:)
        return nil unless CACHE_TTL_SECONDS.positive?
        return nil unless defined?(Rails) && Rails.respond_to?(:cache) && Rails.cache

        "ops:job_execution_metrics_snapshot:#{CACHE_VERSION}:#{window}:#{limit}:#{account_id.to_i}"
      rescue StandardError
        nil
      end
    end
  end
end
