require "json"

module Jobs
  class FailureRetry
    class RetryError < StandardError; end

    class << self
      def enqueue!(failure)
        raise RetryError, "Failure record is required" unless failure
        raise RetryError, "Authentication failures must not be retried" if failure.auth_failure?
        raise RetryError, "Failure is marked as non-retryable" unless failure.retryable_now?

        job_class = failure.job_class.to_s.safe_constantize
        raise RetryError, "Unknown job class: #{failure.job_class}" unless job_class

        payload = parse_arguments(failure.arguments_json)
        job = perform_later(job_class: job_class, payload: payload)

        Ops::LiveUpdateBroadcaster.broadcast!(
          topic: "jobs_changed",
          account_id: failure.instagram_account_id,
          payload: { action: "retry_enqueued", failed_job_id: failure.id, new_job_id: job.job_id },
          throttle_key: "jobs_changed",
          throttle_seconds: 0
        )

        job
      end

      private

      def parse_arguments(raw)
        return [] if raw.blank?

        parsed = JSON.parse(raw)
        parsed.is_a?(Array) ? parsed : [parsed]
      rescue StandardError
        []
      end

      def perform_later(job_class:, payload:)
        if payload.length == 1 && payload.first.is_a?(Hash)
          job_class.perform_later(**payload.first.deep_symbolize_keys)
        else
          job_class.perform_later(*payload)
        end
      rescue ArgumentError
        job_class.perform_later(*payload)
      end
    end
  end
end
