module Admin
  module BackgroundJobs
    class JobSerializer
      SCHEDULING_REASON_LABELS = {
        "ready_to_run" => "Queued for immediate worker pickup.",
        "retry_backoff" => "Delayed by retry backoff after a previous failure.",
        "resource_guard_delay" => "Deferred by local AI resource guard to avoid overload.",
        "timeout_resume_delay" => "Rescheduled after timeout guardrail to resume safely.",
        "dependency_wait_poll" => "Finalizer polling while required dependency jobs complete.",
        "account_batch_continuation" => "Account batching continuation delay between chunks.",
        "account_batch_stagger" => "Staggered account enqueue to smooth worker load.",
        "rate_limit_guard" => "Rate-limit guard delay before the next send attempt.",
        "scheduled_delay" => "Scheduled to run later based on enqueue delay.",
        "unknown_scheduled_delay" => "Scheduled delay reason was not recognized; verify enqueue configuration."
      }.freeze

      def serialize_sidekiq(job:, status:, queue_name:)
        item = job.item.to_h
        wrapper = active_job_wrapper_from_sidekiq(item)
        arguments = wrapper["arguments"] || item["args"] || []
        context = Jobs::ContextExtractor.from_active_job_arguments(arguments)
        class_name = wrapper["job_class"].presence || item["wrapped"].presence || item["class"].to_s
        scheduled_timestamp = item["at"]
        scheduled_timestamp = job.at if scheduled_timestamp.blank? && job.respond_to?(:at)
        scheduled_timestamp = job.score if scheduled_timestamp.blank? && job.respond_to?(:score)
        created_at = parse_epoch_time(item["created_at"] || item["enqueued_at"] || scheduled_timestamp)
        scheduled_for_at = parse_epoch_time(scheduled_timestamp)
        schedule = scheduling_metadata(
          status: status,
          class_name: class_name,
          arguments: arguments,
          item: item,
          scheduled_for_at: scheduled_for_at
        )

        {
          created_at: created_at,
          scheduled_for_at: scheduled_for_at,
          scheduled_in_seconds: seconds_until(scheduled_for_at),
          scheduled_relative_text: relative_schedule_text(scheduled_for_at),
          class_name: class_name,
          queue_name: queue_name.to_s,
          status: status,
          queue_state: queue_state_for(status: status),
          scheduler_service: schedule[:scheduler_service],
          scheduling_reason_code: schedule[:reason_code],
          scheduling_reason: schedule[:reason],
          scheduling_intentional: schedule[:intentional],
          jid: item["jid"].to_s,
          active_job_id: wrapper["job_id"].to_s.presence,
          provider_job_id: wrapper["provider_job_id"].to_s.presence || item["jid"].to_s.presence,
          error_message: item["error_message"].to_s.presence,
          job_scope: context[:job_scope],
          context_label: context[:context_label],
          instagram_account_id: context[:instagram_account_id],
          instagram_profile_id: context[:instagram_profile_id],
          arguments: arguments
        }
      rescue StandardError
        fallback_row(status: status, queue_name: queue_name)
      end

      def serialize_solid_queue(job)
        args = job.respond_to?(:arguments) ? job.arguments : {}
        context = Jobs::ContextExtractor.from_solid_queue_job_arguments(args)
        class_name = (job.class_name if job.respond_to?(:class_name)) || "unknown"
        scheduled_for_at = parse_epoch_time(job.scheduled_at) if job.respond_to?(:scheduled_at)

        status =
          if job.respond_to?(:finished_at) && job.finished_at.present?
            "finished"
          elsif job.respond_to?(:scheduled_at) && job.scheduled_at.present?
            "scheduled"
          else
            "processing"
          end

        schedule = scheduling_metadata(
          status: status,
          class_name: class_name,
          arguments: args,
          item: {},
          scheduled_for_at: scheduled_for_at
        )

        {
          created_at: (job.created_at if job.respond_to?(:created_at)),
          scheduled_for_at: scheduled_for_at,
          scheduled_in_seconds: seconds_until(scheduled_for_at),
          scheduled_relative_text: relative_schedule_text(scheduled_for_at),
          class_name: class_name,
          queue_name: (job.queue_name if job.respond_to?(:queue_name)).to_s,
          status: status,
          queue_state: queue_state_for(status: status),
          scheduler_service: schedule[:scheduler_service],
          scheduling_reason_code: schedule[:reason_code],
          scheduling_reason: schedule[:reason],
          scheduling_intentional: schedule[:intentional],
          jid: (job.id.to_s if job.respond_to?(:id)),
          active_job_id: (job.active_job_id.to_s if job.respond_to?(:active_job_id)).presence,
          provider_job_id: nil,
          error_message: nil,
          job_scope: context[:job_scope],
          context_label: context[:context_label],
          instagram_account_id: context[:instagram_account_id],
          instagram_profile_id: context[:instagram_profile_id],
          arguments: args || []
        }
      rescue StandardError
        fallback_row(status: "unknown", queue_name: "")
      end

      def parse_epoch_time(value)
        return nil if value.blank?
        return value.in_time_zone if value.respond_to?(:in_time_zone)

        return Time.zone.parse(value.to_s) if value.is_a?(String) && value.to_s.match?(/[A-Za-z\-:]/)

        Time.at(value.to_f)
      rescue StandardError
        nil
      end

      private

      def active_job_wrapper_from_sidekiq(item)
        args = Array(item["args"])
        first = args.first
        return first.to_h if first.respond_to?(:to_h) && first.to_h["job_class"].present?

        {}
      rescue StandardError
        {}
      end

      def fallback_row(status:, queue_name:)
        {
          created_at: nil,
          scheduled_for_at: nil,
          scheduled_in_seconds: nil,
          scheduled_relative_text: nil,
          class_name: "unknown",
          queue_name: queue_name.to_s,
          status: status,
          queue_state: queue_state_for(status: status),
          scheduler_service: nil,
          scheduling_reason_code: nil,
          scheduling_reason: nil,
          scheduling_intentional: nil,
          jid: nil,
          active_job_id: nil,
          provider_job_id: nil,
          error_message: nil,
          job_scope: "system",
          context_label: "System",
          instagram_account_id: nil,
          instagram_profile_id: nil,
          arguments: []
        }
      end

      def queue_state_for(status:)
        normalized = status.to_s
        case normalized
        when "enqueued" then "queued"
        when "retry" then "scheduled"
        else normalized
        end
      end

      def scheduling_metadata(status:, class_name:, arguments:, item:, scheduled_for_at:)
        normalized_status = status.to_s
        payload = normalized_argument_payload(arguments)
        retry_count = item.to_h["retry_count"].to_i
        requested_by = payload["requested_by"].to_s
        defer_attempt = payload["defer_attempt"].to_i
        finalize_attempt = payload["attempts"].to_i
        cursor_id = payload["cursor_id"].to_i

        reason_code =
          if normalized_status == "enqueued"
            "ready_to_run"
          elsif normalized_status == "retry" || retry_count.positive?
            "retry_backoff"
          elsif normalized_status == "scheduled" && requested_by.include?("retry")
            "retry_backoff"
          elsif class_name.to_s == "GenerateLlmCommentJob" && defer_attempt.positive?
            "resource_guard_delay"
          elsif class_name.to_s == "GenerateLlmCommentJob" && requested_by.start_with?("timeout_resume:")
            "timeout_resume_delay"
          elsif class_name.to_s == "FinalizeStoryCommentPipelineJob" && finalize_attempt.positive?
            "dependency_wait_poll"
          elsif class_name.to_s == "EnqueueStoryAutoRepliesForAllAccountsJob" && cursor_id.positive?
            "account_batch_continuation"
          elsif class_name.to_s == "SyncProfileStoriesForAccountJob" && normalized_status == "scheduled"
            "account_batch_stagger"
          elsif class_name.to_s == "SendStoryReplyEngagementJob" && normalized_status == "scheduled"
            "rate_limit_guard"
          elsif normalized_status == "scheduled" && scheduled_for_at.present?
            "scheduled_delay"
          elsif normalized_status == "scheduled"
            "unknown_scheduled_delay"
          else
            "ready_to_run"
          end

        scheduler_service =
          case reason_code
          when "retry_backoff"
            "Sidekiq retry set"
          when "account_batch_stagger"
            "EnqueueStoryAutoRepliesForAllAccountsJob"
          when "account_batch_continuation"
            "ScheduledAccountBatching"
          else
            class_name.to_s.presence || "unknown"
          end

        {
          reason_code: reason_code,
          reason: SCHEDULING_REASON_LABELS[reason_code].to_s,
          scheduler_service: scheduler_service,
          intentional: reason_code != "unknown_scheduled_delay"
        }
      rescue StandardError
        {
          reason_code: "unknown_scheduled_delay",
          reason: SCHEDULING_REASON_LABELS["unknown_scheduled_delay"],
          scheduler_service: class_name.to_s.presence || "unknown",
          intentional: false
        }
      end

      def normalized_argument_payload(arguments)
        raw =
          if arguments.is_a?(Hash)
            arguments
          else
            Array(arguments).first
          end
        hash = raw.respond_to?(:to_h) ? raw.to_h : {}

        nested = hash["arguments"] || hash[:arguments]
        return normalized_argument_payload(nested) if nested.present?

        hash.deep_stringify_keys
      rescue StandardError
        {}
      end

      def seconds_until(time_value)
        return nil unless time_value

        (time_value.to_f - Time.current.to_f).round
      rescue StandardError
        nil
      end

      def relative_schedule_text(time_value)
        delta_seconds = seconds_until(time_value)
        return nil if delta_seconds.nil?
        return "runs now" if delta_seconds.abs <= 5

        if delta_seconds.positive?
          "runs in #{human_duration(delta_seconds)}"
        else
          "was due #{human_duration(delta_seconds.abs)} ago"
        end
      rescue StandardError
        nil
      end

      def human_duration(seconds)
        value = seconds.to_i
        return "#{value}s" if value < 60

        minutes = (value / 60.0).round
        return "#{minutes}m" if minutes < 120

        hours = (minutes / 60.0).round
        "#{hours}h"
      rescue StandardError
        "#{seconds.to_i}s"
      end
    end
  end
end
