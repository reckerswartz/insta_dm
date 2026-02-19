module Jobs
  class ContextExtractor
    class << self
      def from_active_job_arguments(arguments)
        payload = normalize_arguments_payload(arguments)

        account_id = extract_int(payload, :instagram_account_id)
        profile_id = extract_int(payload, :instagram_profile_id)
        profile_post_id = extract_int(payload, :instagram_profile_post_id)

        scope = if profile_id.present?
          "profile"
        elsif account_id.present?
          "account"
        else
          "system"
        end

        {
          instagram_account_id: account_id,
          instagram_profile_id: profile_id,
          instagram_profile_post_id: profile_post_id,
          job_scope: scope,
          context_label: context_label(scope: scope, account_id: account_id, profile_id: profile_id)
        }
      rescue StandardError
        {
          instagram_account_id: nil,
          instagram_profile_id: nil,
          instagram_profile_post_id: nil,
          job_scope: "system",
          context_label: "System"
        }
      end

      def from_solid_queue_job_arguments(arguments)
        hash = arguments.is_a?(Hash) ? arguments : {}
        inner = hash["arguments"] || hash[:arguments]
        from_active_job_arguments(inner)
      end

      def from_sidekiq_item(item)
        hash = item.is_a?(Hash) ? item : {}
        args = Array(hash["args"])
        wrapper = args.first
        if wrapper.is_a?(Hash) && wrapper["arguments"].present?
          return from_active_job_arguments(wrapper["arguments"])
        end

        from_active_job_arguments(args)
      end

      private

      def normalize_arguments_payload(arguments)
        first = Array(arguments).first
        return normalize_hash(first) if first.is_a?(Hash)

        hash = normalize_hash(arguments)
        nested = hash["arguments"] || hash[:arguments]
        return normalize_arguments_payload(nested) if nested.present?

        hash
      end

      def normalize_hash(value)
        return value.to_h if value.respond_to?(:to_h)

        {}
      rescue StandardError
        {}
      end

      def extract_int(hash, key)
        value = hash[key.to_s] || hash[key.to_sym]
        return nil if value.blank?

        Integer(value)
      rescue StandardError
        nil
      end

      def context_label(scope:, account_id:, profile_id:)
        case scope
        when "profile" then "Profile ##{profile_id} (Account ##{account_id || '?'})"
        when "account" then "Account ##{account_id}"
        else "System"
        end
      end
    end
  end
end
