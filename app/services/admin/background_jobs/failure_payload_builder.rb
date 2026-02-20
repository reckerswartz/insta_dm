module Admin
  module BackgroundJobs
    class FailurePayloadBuilder
      def initialize(failures:, total:, pages:, routes: Rails.application.routes.url_helpers)
        @failures = failures
        @total = total
        @pages = pages
        @routes = routes
      end

      def call
        {
          data: failures.map { |failure| serialize_failure(failure) },
          last_page: pages,
          last_row: total
        }
      end

      private

      attr_reader :failures, :total, :pages, :routes

      def serialize_failure(failure)
        scope = failure_scope(failure)

        {
          id: failure.id,
          occurred_at: failure.occurred_at&.iso8601,
          job_scope: scope,
          context_label: failure_context_label(failure: failure, scope: scope),
          instagram_account_id: failure.instagram_account_id,
          instagram_profile_id: failure.instagram_profile_id,
          job_class: failure.job_class,
          queue_name: failure.queue_name,
          failure_kind: failure.failure_kind,
          retryable: failure.retryable_now?,
          error_class: failure.error_class,
          error_message: failure.error_message,
          open_url: routes.admin_background_job_failure_path(failure),
          retry_url: routes.admin_retry_background_job_failure_path(failure)
        }
      end

      def failure_scope(failure)
        return "profile" if failure.instagram_profile_id.present?
        return "account" if failure.instagram_account_id.present?

        "system"
      end

      def failure_context_label(failure:, scope:)
        case scope
        when "profile"
          "Profile ##{failure.instagram_profile_id} (Account ##{failure.instagram_account_id || '?'})"
        when "account"
          "Account ##{failure.instagram_account_id}"
        else
          "System"
        end
      end
    end
  end
end
