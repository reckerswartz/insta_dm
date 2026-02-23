module Ops
  class ServiceOutputAuditSnapshot
    DEFAULT_WINDOW_HOURS = ENV.fetch("SERVICE_OUTPUT_AUDIT_WINDOW_HOURS", 24).to_i.clamp(1, 168)
    DEFAULT_SERVICE_LIMIT = ENV.fetch("SERVICE_OUTPUT_AUDIT_SERVICE_LIMIT", 20).to_i.clamp(1, 100)
    DEFAULT_KEY_LIMIT = ENV.fetch("SERVICE_OUTPUT_AUDIT_KEY_LIMIT", 25).to_i.clamp(1, 100)
    CACHE_TTL_SECONDS = ENV.fetch("SERVICE_OUTPUT_AUDIT_CACHE_TTL_SECONDS", 30).to_i.clamp(0, 300)
    CACHE_VERSION = "v1".freeze

    class << self
      def snapshot(window_hours: DEFAULT_WINDOW_HOURS, service_limit: DEFAULT_SERVICE_LIMIT, key_limit: DEFAULT_KEY_LIMIT, account_id: nil, use_cache: true)
        window = window_hours.to_i.clamp(1, 168)
        limit = service_limit.to_i.clamp(1, 100)
        key_cap = key_limit.to_i.clamp(1, 100)
        account = account_id.to_i.positive? ? account_id.to_i : nil
        cache_key = cache_key_for(window: window, service_limit: limit, key_limit: key_cap, account_id: account)

        if use_cache && cache_key
          return Rails.cache.fetch(cache_key, expires_in: CACHE_TTL_SECONDS.seconds) do
            build_snapshot(window_hours: window, service_limit: limit, key_limit: key_cap, account_id: account)
          end
        end

        build_snapshot(window_hours: window, service_limit: limit, key_limit: key_cap, account_id: account)
      end

      private

      def build_snapshot(window_hours:, service_limit:, key_limit:, account_id:)
        scope = scoped_rows(window_hours: window_hours, account_id: account_id)
        rows = scope.limit(5_000).to_a

        {
          captured_at: Time.current.iso8601(3),
          window_hours: window_hours,
          account_id: account_id,
          total_rows: scope.count.to_i,
          completed_rows: scope.where(status: "completed").count.to_i,
          failed_rows: scope.where(status: "failed").count.to_i,
          unique_services: scope.distinct.count(:service_name).to_i,
          avg_unused_count: average_numeric(scope: scope, column: :unused_count),
          avg_produced_count: average_numeric(scope: scope, column: :produced_count),
          services: service_rows(rows: rows, limit: service_limit),
          top_unused_leaf_keys: key_frequency(rows: rows, field: :unused_leaf_keys, limit: key_limit),
          top_persisted_paths: key_frequency(rows: rows, field: :persisted_paths, limit: key_limit),
          top_produced_leaf_keys: key_frequency(rows: rows, field: :produced_leaf_keys, limit: key_limit)
        }
      rescue StandardError
        empty_snapshot(window_hours: window_hours, account_id: account_id)
      end

      def scoped_rows(window_hours:, account_id:)
        scope = ServiceOutputAudit.within(window_hours.hours.ago..Time.current)
        scope = scope.where(instagram_account_id: account_id.to_i) if account_id.to_i.positive?
        scope
      rescue StandardError
        ServiceOutputAudit.none
      end

      def service_rows(rows:, limit:)
        grouped = Array(rows).group_by(&:service_name)
        grouped.map do |service_name, service_rows|
          executions = service_rows.length
          completed = service_rows.count { |row| row.status.to_s == "completed" }
          failed = service_rows.count { |row| row.status.to_s == "failed" }
          produced_total = service_rows.sum { |row| row.produced_count.to_i }
          persisted_total = service_rows.sum { |row| row.persisted_count.to_i }
          referenced_total = service_rows.sum { |row| row.referenced_count.to_i }
          unused_total = service_rows.sum { |row| row.unused_count.to_i }
          top_unused_keys = key_frequency(rows: service_rows, field: :unused_leaf_keys, limit: 8)

          {
            service_name: service_name.to_s,
            executions: executions,
            completed: completed,
            failed: failed,
            avg_produced_count: average_rows(service_rows, &:produced_count),
            avg_persisted_count: average_rows(service_rows, &:persisted_count),
            avg_referenced_count: average_rows(service_rows, &:referenced_count),
            avg_unused_count: average_rows(service_rows, &:unused_count),
            persisted_ratio: ratio(numerator: persisted_total, denominator: produced_total),
            used_ratio: ratio(numerator: (persisted_total + referenced_total), denominator: produced_total),
            unused_ratio: ratio(numerator: unused_total, denominator: produced_total),
            top_unused_keys: top_unused_keys,
            last_recorded_at: service_rows.map(&:recorded_at).compact.max&.iso8601(3)
          }
        end.sort_by { |row| [ -row[:executions].to_i, -row[:avg_unused_count].to_f, row[:service_name].to_s ] }.first(limit.to_i)
      rescue StandardError
        []
      end

      def key_frequency(rows:, field:, limit:)
        counts = Hash.new(0)
        Array(rows).each do |row|
          Array(row.public_send(field)).each do |key|
            normalized = key.to_s.strip
            next if normalized.blank?

            counts[normalized] += 1
          end
        end

        counts
          .sort_by { |key, count| [ -count.to_i, key.to_s ] }
          .first(limit.to_i)
          .map { |key, count| { key: key, count: count.to_i } }
      rescue StandardError
        []
      end

      def average_numeric(scope:, column:)
        scope.where.not(column => nil).average(column)&.round(2)
      rescue StandardError
        nil
      end

      def average_rows(rows)
        values = Array(rows).map { |row| yield(row).to_i }
        return 0.0 if values.empty?

        (values.sum.to_f / values.length.to_f).round(2)
      rescue StandardError
        0.0
      end

      def ratio(numerator:, denominator:)
        return 0.0 if denominator.to_i <= 0

        ((numerator.to_f / denominator.to_f) * 100.0).round(2)
      rescue StandardError
        0.0
      end

      def empty_snapshot(window_hours:, account_id:)
        {
          captured_at: Time.current.iso8601(3),
          window_hours: window_hours.to_i,
          account_id: account_id,
          total_rows: 0,
          completed_rows: 0,
          failed_rows: 0,
          unique_services: 0,
          avg_unused_count: 0.0,
          avg_produced_count: 0.0,
          services: [],
          top_unused_leaf_keys: [],
          top_persisted_paths: [],
          top_produced_leaf_keys: []
        }
      end

      def cache_key_for(window:, service_limit:, key_limit:, account_id:)
        return nil unless CACHE_TTL_SECONDS.positive?
        return nil unless defined?(Rails) && Rails.respond_to?(:cache) && Rails.cache

        "ops:service_output_audit_snapshot:#{CACHE_VERSION}:#{window}:#{service_limit}:#{key_limit}:#{account_id.to_i}"
      rescue StandardError
        nil
      end
    end
  end
end
