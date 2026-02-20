module Admin
  module BackgroundJobs
    class RecentJobDetailsEnricher
      def initialize(rows:, details_builder: JobDetailsBuilder.new)
        @rows = Array(rows)
        @details_builder = details_builder
      end

      def call
        return rows if rows.empty?

        active_job_ids = rows.map { |row| row[:active_job_id].to_s.presence }.compact.uniq
        action_logs_by_job_id = load_action_logs_by_job_id(active_job_ids: active_job_ids)
        failures_by_job_id = load_failures_by_job_id(active_job_ids: active_job_ids)
        ingestions_by_job_id = load_ingestions_by_job_id(active_job_ids: active_job_ids)
        llm_events_by_job_id = load_llm_events_by_job_id(active_job_ids: active_job_ids)
        api_calls_by_job_id = load_api_calls_by_job_id(active_job_ids: active_job_ids)

        rows.each do |row|
          active_job_id = row[:active_job_id].to_s
          row[:details] = details_builder.call(
            row: row,
            action_log: action_logs_by_job_id[active_job_id]&.first,
            failure: failures_by_job_id[active_job_id]&.first,
            direct_ingestions: ingestions_by_job_id[active_job_id] || [],
            direct_llm_events: llm_events_by_job_id[active_job_id] || [],
            direct_api_calls: api_calls_by_job_id[active_job_id] || []
          )
        end

        rows
      rescue StandardError
        rows.each { |row| row[:details] = details_builder.fallback(row: row) }
        rows
      end

      private

      attr_reader :rows, :details_builder

      def load_action_logs_by_job_id(active_job_ids:)
        return {} if active_job_ids.empty?

        InstagramProfileActionLog
          .includes(:instagram_account, :instagram_profile)
          .where(active_job_id: active_job_ids)
          .order(created_at: :desc)
          .to_a
          .group_by { |row| row.active_job_id.to_s }
      rescue StandardError
        {}
      end

      def load_failures_by_job_id(active_job_ids:)
        return {} if active_job_ids.empty?

        BackgroundJobFailure
          .where(active_job_id: active_job_ids)
          .order(occurred_at: :desc, id: :desc)
          .to_a
          .group_by { |row| row.active_job_id.to_s }
      rescue StandardError
        {}
      end

      def load_ingestions_by_job_id(active_job_ids:)
        return {} if active_job_ids.empty?

        ActiveStorageIngestion
          .where(created_by_active_job_id: active_job_ids)
          .order(created_at: :desc, id: :desc)
          .limit(400)
          .to_a
          .group_by { |row| row.created_by_active_job_id.to_s }
      rescue StandardError
        {}
      end

      def load_llm_events_by_job_id(active_job_ids:)
        return {} if active_job_ids.empty?

        InstagramProfileEvent
          .where(llm_comment_job_id: active_job_ids)
          .order(updated_at: :desc, id: :desc)
          .limit(300)
          .to_a
          .group_by { |row| row.llm_comment_job_id.to_s }
      rescue StandardError
        {}
      end

      def load_api_calls_by_job_id(active_job_ids:)
        return {} if active_job_ids.empty?

        index = Hash.new { |hash, key| hash[key] = [] }
        AiApiCall.recent_first.limit(600).to_a.each do |call|
          metadata = call.metadata.is_a?(Hash) ? call.metadata : {}
          active_job_id = metadata["active_job_id"].to_s
          next if active_job_id.blank? || !active_job_ids.include?(active_job_id)

          index[active_job_id] << call
        end
        index
      rescue StandardError
        {}
      end
    end
  end
end
