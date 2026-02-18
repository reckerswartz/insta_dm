require "digest"

module Ops
  class IssueTracker
    class << self
      def record_job_failure!(job:, exception:, context:, failure_record:)
        issue_type = exception.is_a?(Instagram::AuthenticationRequiredError) ? "authentication_required" : "job_failure"
        severity = exception.is_a?(Instagram::AuthenticationRequiredError) ? "critical" : "error"

        upsert_issue!(
          issue_type: issue_type,
          source: job.class.name,
          severity: severity,
          title: issue_title_for(job: job, exception: exception),
          details: exception.message.to_s,
          instagram_account_id: context[:instagram_account_id],
          instagram_profile_id: context[:instagram_profile_id],
          background_job_failure_id: failure_record&.id,
          metadata: {
            queue_name: job.queue_name,
            active_job_id: job.job_id,
            provider_job_id: job.provider_job_id,
            error_class: exception.class.name
          },
          fingerprint: fingerprint_for_job_failure(job: job, exception: exception, context: context)
        )
      end

      def record_ai_service_check!(ok:, message:, metadata: {})
        if ok
          resolve_by_fingerprint!(
            fingerprint: fingerprint_for("ai_service_health", "AiDashboardController", nil, nil, "ai_microservice_offline"),
            notes: "AI microservice healthy again."
          )
          return
        end

        upsert_issue!(
          issue_type: "ai_service_unavailable",
          source: "AiDashboardController",
          severity: "critical",
          title: "AI microservice unavailable",
          details: message.to_s,
          metadata: metadata,
          fingerprint: fingerprint_for("ai_service_health", "AiDashboardController", nil, nil, "ai_microservice_offline")
        )
      end

      def resolve_by_fingerprint!(fingerprint:, notes: nil)
        issue = AppIssue.find_by(fingerprint: fingerprint.to_s)
        return unless issue
        return if issue.status == "resolved"

        issue.mark_resolved!(notes: notes)
      rescue StandardError => e
        Rails.logger.warn("[ops.issue_tracker] resolve failed: #{e.class}: #{e.message}")
      end

      def upsert_issue!(issue_type:, source:, severity:, title:, details:, metadata: {}, fingerprint:, instagram_account_id: nil, instagram_profile_id: nil, background_job_failure_id: nil)
        now = Time.current
        issue = AppIssue.find_or_initialize_by(fingerprint: fingerprint.to_s)

        issue.issue_type = issue_type.to_s
        issue.source = source.to_s
        issue.severity = normalize_severity(severity)
        issue.title = title.to_s
        issue.details = details.to_s
        issue.instagram_account_id = instagram_account_id
        issue.instagram_profile_id = instagram_profile_id
        issue.background_job_failure_id = background_job_failure_id
        issue.metadata = (issue.metadata || {}).merge(metadata.to_h)
        issue.first_seen_at ||= now
        issue.last_seen_at = now
        issue.occurrences = issue.new_record? ? 1 : issue.occurrences.to_i + 1
        issue.status = "open"
        issue.resolved_at = nil
        issue.save!
        issue
      rescue StandardError => e
        Rails.logger.warn("[ops.issue_tracker] upsert failed: #{e.class}: #{e.message}")
        nil
      end

      private

      def issue_title_for(job:, exception:)
        if exception.is_a?(Instagram::AuthenticationRequiredError)
          "Authentication required for #{job.class.name}"
        else
          "Job failure in #{job.class.name}"
        end
      end

      def normalize_severity(value)
        sev = value.to_s
        AppIssue::SEVERITIES.include?(sev) ? sev : "error"
      end

      def fingerprint_for_job_failure(job:, exception:, context:)
        key =
          if exception.is_a?(Instagram::AuthenticationRequiredError)
            "authentication_required"
          else
            normalized_error_message(exception.message.to_s)
          end

        fingerprint_for(
          "job_failure",
          job.class.name,
          context[:instagram_account_id],
          context[:instagram_profile_id],
          key
        )
      end

      def fingerprint_for(issue_type, source, account_id, profile_id, key)
        Digest::SHA256.hexdigest([issue_type, source, account_id, profile_id, key].map(&:to_s).join("|"))
      end

      def normalized_error_message(msg)
        msg.to_s
          .gsub(/\b\d{2,}\b/, "<n>")
          .gsub(/[0-9a-f]{8,}/i, "<hex>")
          .truncate(180)
      end
    end
  end
end
