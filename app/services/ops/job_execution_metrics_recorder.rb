module Ops
  class JobExecutionMetricsRecorder
    ENABLED = ActiveModel::Type::Boolean.new.cast(
      ENV.fetch("JOB_EXECUTION_METRICS_ENABLED", "true")
    )
    TERMINAL_STATES = %w[completed failed].freeze
    RESERVED_KEYS = %w[
      transition
      sidekiq_jid
      active_job_id
      provider_job_id
      sidekiq_class
      job_class
      queue_name
      retry_count
      queue_wait_ms
      processing_duration_ms
      total_time_ms
      transition_recorded_at_ms
      instagram_account_id
      instagram_profile_id
      instagram_profile_post_id
    ].freeze

    class << self
      def record_transition(payload:)
        return unless ENABLED
        return unless metrics_table_available?

        row = payload.is_a?(Hash) ? payload.deep_symbolize_keys : {}
        status = row[:transition].to_s
        return unless TERMINAL_STATES.include?(status)

        queue_name = row[:queue_name].to_s.strip
        job_class = row[:job_class].to_s.strip
        return if queue_name.blank? || job_class.blank?

        recorded_at = timestamp_from_ms(row[:transition_recorded_at_ms]) || Time.current
        active_job_id = row[:active_job_id].to_s.presence || row[:provider_job_id].to_s.presence || row[:sidekiq_jid].to_s.presence
        return if active_job_id.to_s.blank?

        BackgroundJobExecutionMetric.create!(
          active_job_id: active_job_id,
          provider_job_id: row[:provider_job_id].to_s.presence,
          sidekiq_jid: row[:sidekiq_jid].to_s.presence,
          sidekiq_class: row[:sidekiq_class].to_s.presence,
          job_class: job_class,
          queue_name: queue_name,
          status: status,
          retry_count: integer_or_nil(row[:retry_count]),
          queue_wait_ms: duration_or_nil(row[:queue_wait_ms]),
          processing_duration_ms: duration_or_nil(row[:processing_duration_ms]),
          total_time_ms: duration_or_nil(row[:total_time_ms]),
          transition_recorded_at_ms: integer_or_nil(row[:transition_recorded_at_ms]),
          instagram_account_id: integer_or_nil(row[:instagram_account_id]),
          instagram_profile_id: integer_or_nil(row[:instagram_profile_id]),
          instagram_profile_post_id: integer_or_nil(row[:instagram_profile_post_id]),
          recorded_at: recorded_at,
          metadata: additional_metadata(row)
        )
      rescue StandardError
        nil
      end

      private

      def metrics_table_available?
        return @metrics_table_available unless @metrics_table_available.nil?

        @metrics_table_available = BackgroundJobExecutionMetric.table_exists?
      rescue StandardError
        @metrics_table_available = false
      end

      def additional_metadata(payload)
        row = payload.deep_stringify_keys
        row.except(*RESERVED_KEYS)
      rescue StandardError
        {}
      end

      def duration_or_nil(value)
        number = integer_or_nil(value)
        return nil unless number

        number.clamp(0, 7.days.in_milliseconds)
      rescue StandardError
        nil
      end

      def integer_or_nil(value)
        return nil if value.nil?

        Integer(value)
      rescue StandardError
        nil
      end

      def timestamp_from_ms(value)
        return nil unless value

        Time.zone.at(value.to_f / 1000.0)
      rescue StandardError
        nil
      end
    end
  end
end
