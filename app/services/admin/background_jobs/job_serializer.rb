module Admin
  module BackgroundJobs
    class JobSerializer
      def serialize_sidekiq(job:, status:, queue_name:)
        item = job.item.to_h
        wrapper = active_job_wrapper_from_sidekiq(item)
        context = Jobs::ContextExtractor.from_active_job_arguments(wrapper["arguments"] || item["args"])

        {
          created_at: parse_epoch_time(item["created_at"] || item["enqueued_at"] || item["at"]),
          class_name: wrapper["job_class"].presence || item["wrapped"].presence || item["class"].to_s,
          queue_name: queue_name.to_s,
          status: status,
          jid: item["jid"].to_s,
          active_job_id: wrapper["job_id"].to_s.presence,
          provider_job_id: wrapper["provider_job_id"].to_s.presence || item["jid"].to_s.presence,
          error_message: item["error_message"].to_s.presence,
          job_scope: context[:job_scope],
          context_label: context[:context_label],
          instagram_account_id: context[:instagram_account_id],
          instagram_profile_id: context[:instagram_profile_id],
          arguments: wrapper["arguments"] || item["args"] || []
        }
      rescue StandardError
        fallback_row(status: status, queue_name: queue_name)
      end

      def serialize_solid_queue(job)
        args = job.respond_to?(:arguments) ? job.arguments : {}
        context = Jobs::ContextExtractor.from_solid_queue_job_arguments(args)

        status =
          if job.respond_to?(:finished_at) && job.finished_at.present?
            "finished"
          elsif job.respond_to?(:scheduled_at) && job.scheduled_at.present?
            "scheduled"
          else
            "running/queued"
          end

        {
          created_at: (job.created_at if job.respond_to?(:created_at)),
          class_name: (job.class_name if job.respond_to?(:class_name)) || "unknown",
          queue_name: (job.queue_name if job.respond_to?(:queue_name)).to_s,
          status: status,
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
          class_name: "unknown",
          queue_name: queue_name.to_s,
          status: status,
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
    end
  end
end
