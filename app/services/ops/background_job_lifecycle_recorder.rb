module Ops
  class BackgroundJobLifecycleRecorder
    TRACKED_STATUSES = BackgroundJobLifecycle::STATUSES.freeze
    RESERVED_METADATA_KEYS = %w[
      status
      transition
      transition_at
      transition_recorded_at_ms
      active_job_id
      provider_job_id
      sidekiq_jid
      sidekiq_class
      job_class
      queue_name
      instagram_account_id
      instagram_profile_id
      instagram_profile_post_id
      related_model_type
      related_model_id
      story_id
      error_class
      error_message
    ].freeze

    class << self
      def record_active_job_transition(job:, status:, context: nil, transition_at: Time.current, error: nil, metadata: {})
        return unless lifecycle_table_available?

        job_context = context || Jobs::ContextExtractor.from_active_job_arguments(job.arguments)
        related_type, related_id = related_model_for_context(job_context)
        payload = {
          status: status.to_s,
          transition_at: transition_at,
          active_job_id: job.job_id.to_s,
          provider_job_id: job.provider_job_id.to_s.presence,
          sidekiq_jid: job.provider_job_id.to_s.presence,
          job_class: job.class.name,
          queue_name: job.queue_name.to_s,
          instagram_account_id: job_context[:instagram_account_id],
          instagram_profile_id: job_context[:instagram_profile_id],
          instagram_profile_post_id: job_context[:instagram_profile_post_id],
          related_model_type: related_type,
          related_model_id: related_id,
          story_id: extract_story_id(job.arguments),
          error_class: error&.class&.name,
          error_message: error&.message,
          metadata: {
            active_job_executions: job.executions,
            locale: job.locale,
            timezone: job.timezone
          }.merge(normalize_metadata(metadata))
        }

        record_transition(payload: payload)
      rescue StandardError
        nil
      end

      def record_sidekiq_removal(entry:, reason:)
        return unless lifecycle_table_available?

        item = normalized_sidekiq_item(entry: entry)
        return if item.empty?

        transition_at = Time.current
        info = extract_sidekiq_info(item: item, queue_name: sidekiq_queue_name(entry: entry, item: item))
        payload = info.merge(
          status: "removed",
          transition_at: transition_at,
          metadata: {
            removal_reason: reason.to_s,
            removed_by: "mission_control_jobs"
          }
        )
        record_transition(payload: payload)
      rescue StandardError
        nil
      end

      def record_transition(payload:)
        return unless lifecycle_table_available?

        row = payload.is_a?(Hash) ? payload.deep_symbolize_keys : {}
        status = normalize_status(row[:status] || row[:transition])
        return unless status

        active_job_id = row[:active_job_id].to_s.presence ||
          row[:provider_job_id].to_s.presence ||
          row[:sidekiq_jid].to_s.presence
        return if active_job_id.blank?

        queue_name = row[:queue_name].to_s.presence || "default"
        job_class = row[:job_class].to_s.presence || row[:sidekiq_class].to_s.presence || "UnknownJob"
        transition_at = normalize_timestamp(row[:transition_at]) ||
          normalize_timestamp(row[:transition_recorded_at_ms]) ||
          Time.current

        lifecycle = BackgroundJobLifecycle.find_or_initialize_by(active_job_id: active_job_id)
        return lifecycle if stale_transition?(lifecycle: lifecycle, transition_at: transition_at)

        lifecycle.provider_job_id = row[:provider_job_id].to_s.presence || lifecycle.provider_job_id
        lifecycle.sidekiq_jid = row[:sidekiq_jid].to_s.presence || lifecycle.sidekiq_jid
        lifecycle.sidekiq_class = row[:sidekiq_class].to_s.presence || lifecycle.sidekiq_class
        lifecycle.job_class = job_class
        lifecycle.queue_name = queue_name
        lifecycle.status = status
        lifecycle.instagram_account_id = integer_or_nil(row[:instagram_account_id]) || lifecycle.instagram_account_id
        lifecycle.instagram_profile_id = integer_or_nil(row[:instagram_profile_id]) || lifecycle.instagram_profile_id
        lifecycle.instagram_profile_post_id = integer_or_nil(row[:instagram_profile_post_id]) || lifecycle.instagram_profile_post_id
        related_type = row[:related_model_type].to_s.presence
        related_id = integer_or_nil(row[:related_model_id])
        if related_type.blank? || related_id.blank?
          inferred_type, inferred_id = related_model_for_ids(
            account_id: lifecycle.instagram_account_id,
            profile_id: lifecycle.instagram_profile_id,
            profile_post_id: lifecycle.instagram_profile_post_id
          )
          related_type ||= inferred_type
          related_id ||= inferred_id
        end
        lifecycle.related_model_type = related_type || lifecycle.related_model_type
        lifecycle.related_model_id = related_id || lifecycle.related_model_id
        lifecycle.story_id = row[:story_id].to_s.presence || lifecycle.story_id
        lifecycle.error_class = row[:error_class].to_s.presence if status.in?(%w[failed discarded])
        lifecycle.error_message = row[:error_message].to_s.presence if status.in?(%w[failed discarded])
        lifecycle.last_transition_at = transition_at
        lifecycle.metadata = merged_metadata(existing: lifecycle.metadata, payload: row)
        apply_status_timestamp!(lifecycle: lifecycle, status: status, transition_at: transition_at)

        lifecycle.save!
        lifecycle
      rescue StandardError
        nil
      end

      private

      def lifecycle_table_available?
        BackgroundJobLifecycle.table_exists?
      rescue StandardError
        false
      end

      def normalize_status(value)
        status = value.to_s
        return nil unless TRACKED_STATUSES.include?(status)

        status
      end

      def normalize_timestamp(value)
        case value
        when Time
          value
        when Integer
          Time.zone.at(value.to_f / 1000.0)
        when Float
          Time.zone.at(value / 1000.0)
        when String
          Time.zone.parse(value)
        else
          nil
        end
      rescue StandardError
        nil
      end

      def stale_transition?(lifecycle:, transition_at:)
        return false unless lifecycle.persisted?
        return false if lifecycle.last_transition_at.blank?

        transition_at < lifecycle.last_transition_at
      end

      def apply_status_timestamp!(lifecycle:, status:, transition_at:)
        case status
        when "queued"
          lifecycle.queued_at ||= transition_at
        when "running"
          lifecycle.started_at ||= transition_at
        when "completed"
          lifecycle.completed_at = transition_at
        when "failed"
          lifecycle.failed_at = transition_at
        when "discarded"
          lifecycle.discarded_at = transition_at
        when "removed"
          lifecycle.removed_at = transition_at
        end
      end

      def merged_metadata(existing:, payload:)
        current = existing.is_a?(Hash) ? existing.deep_stringify_keys : {}
        incoming = payload[:metadata]
        incoming = incoming.is_a?(Hash) ? incoming.deep_stringify_keys : {}
        derived = payload.deep_stringify_keys.except(*RESERVED_METADATA_KEYS)

        current.merge(derived).merge(incoming)
      rescue StandardError
        current || {}
      end

      def normalize_metadata(value)
        return {} unless value.is_a?(Hash)

        value.deep_stringify_keys
      rescue StandardError
        {}
      end

      def integer_or_nil(value)
        return nil if value.nil?

        Integer(value)
      rescue StandardError
        nil
      end

      def related_model_for_context(context)
        row = context.is_a?(Hash) ? context.deep_symbolize_keys : {}
        related_model_for_ids(
          account_id: row[:instagram_account_id],
          profile_id: row[:instagram_profile_id],
          profile_post_id: row[:instagram_profile_post_id]
        )
      rescue StandardError
        [ nil, nil ]
      end

      def related_model_for_ids(account_id:, profile_id:, profile_post_id:)
        if profile_post_id.present?
          [ "InstagramProfilePost", profile_post_id.to_i ]
        elsif profile_id.present?
          [ "InstagramProfile", profile_id.to_i ]
        elsif account_id.present?
          [ "InstagramAccount", account_id.to_i ]
        else
          [ nil, nil ]
        end
      end

      def extract_story_id(arguments)
        first = Array(arguments).first
        return nil unless first.is_a?(Hash)

        (first[:story_id] || first["story_id"]).to_s.presence
      rescue StandardError
        nil
      end

      def normalized_sidekiq_item(entry:)
        return entry.item if entry.respond_to?(:item) && entry.item.is_a?(Hash)

        entry.is_a?(Hash) ? entry : {}
      rescue StandardError
        {}
      end

      def sidekiq_queue_name(entry:, item:)
        queue = entry.respond_to?(:queue) ? entry.queue : nil
        queue.to_s.presence || item["queue"].to_s.presence || "default"
      rescue StandardError
        "default"
      end

      def extract_sidekiq_info(item:, queue_name:)
        wrapper = active_job_wrapper(item: item)
        if wrapper
          arguments = wrapper["arguments"]
          context = Jobs::ContextExtractor.from_active_job_arguments(arguments)
          related_type, related_id = related_model_for_context(context)
          {
            active_job_id: wrapper["job_id"].to_s.presence || item["jid"].to_s,
            provider_job_id: item["jid"].to_s.presence,
            sidekiq_jid: item["jid"].to_s.presence,
            sidekiq_class: item["class"].to_s.presence,
            job_class: wrapper["job_class"].to_s.presence || item["class"].to_s,
            queue_name: wrapper["queue_name"].to_s.presence || queue_name,
            instagram_account_id: context[:instagram_account_id],
            instagram_profile_id: context[:instagram_profile_id],
            instagram_profile_post_id: context[:instagram_profile_post_id],
            related_model_type: related_type,
            related_model_id: related_id,
            story_id: extract_story_id(arguments)
          }
        else
          {
            active_job_id: item["jid"].to_s,
            provider_job_id: item["jid"].to_s.presence,
            sidekiq_jid: item["jid"].to_s.presence,
            sidekiq_class: item["class"].to_s.presence,
            job_class: item["class"].to_s.presence || "UnknownJob",
            queue_name: queue_name
          }
        end
      end

      def active_job_wrapper(item:)
        return nil unless item["class"].to_s == "ActiveJob::QueueAdapters::SidekiqAdapter::JobWrapper"

        args = item["args"]
        first = args.is_a?(Array) ? args.first : nil
        first.is_a?(Hash) ? first : nil
      rescue StandardError
        nil
      end
    end
  end
end
