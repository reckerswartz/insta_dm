require "sidekiq"

module Ops
  # Server-side Sidekiq middleware that catches payloads whose Active Job class
  # no longer exists (e.g. a job class deleted in a prior migration that still
  # has retry/dead/scheduled entries in Redis). Without this middleware Sidekiq
  # raises `NameError` → the job moves back to the retry set → next retry
  # raises `NameError` again, forever, and the top-level `config.error_handlers`
  # hook crashes too because it can't resolve the class name either.
  #
  # Fix: rescue the class-resolution failure, record a single
  # `BackgroundJobFailure(failure_kind: "deprovisioned_class", retryable:
  # false)` entry, and return from the middleware without re-raising. Sidekiq
  # treats that as a successful run and discards the payload permanently.
  #
  # See `docs/audits/phase13/FINDINGS.md#F-admin-background-jobs-C1`.
  class OrphanedJobClassMiddleware
    include Sidekiq::ServerMiddleware

    def call(_worker, msg, _queue)
      yield
    rescue NameError => error
      klass = candidate_class_name(msg)
      raise unless klass.present? && orphaned_class?(klass)

      Rails.logger.warn(
        "[sidekiq] Dropping orphaned payload class=#{klass} jid=#{msg['jid']} " \
        "queue=#{msg['queue']} reason=#{error.class}: #{error.message}"
      )

      record_orphaned_failure(msg: msg, klass: klass, error: error)
      # Swallow — Sidekiq marks the job acknowledged and removes it from any
      # retry/dead/scheduled set.
    rescue ActiveJob::UnknownJobClassError => error
      klass = candidate_class_name(msg)
      Rails.logger.warn(
        "[sidekiq] Dropping payload with unknown Active Job class=#{klass} " \
        "jid=#{msg['jid']} queue=#{msg['queue']}: #{error.message}"
      )
      record_orphaned_failure(msg: msg, klass: klass.presence || "UnknownJob", error: error)
    end

    private

    def candidate_class_name(msg)
      msg["wrapped"].presence || msg["class"].presence
    end

    def orphaned_class?(klass)
      return false if klass.blank?

      klass.constantize
      false
    rescue NameError
      true
    end

    def record_orphaned_failure(msg:, klass:, error:)
      active_job_payload = Array(msg["args"]).first
      active_job_id = active_job_payload.is_a?(Hash) ? active_job_payload["job_id"] : nil
      arguments = []
      if active_job_payload.is_a?(Hash) && active_job_payload["arguments"].is_a?(Array)
        arguments = active_job_payload["arguments"]
      end

      BackgroundJobFailure.create!(
        job_class: klass,
        queue_name: msg["queue"],
        failure_kind: "deprovisioned_class",
        retryable: false,
        error_class: error.class.name,
        error_message: error.message.to_s.first(2_000),
        active_job_id: active_job_id,
        provider_job_id: msg["jid"],
        arguments_json: arguments.to_json,
        occurred_at: Time.current,
        metadata: {
          captured_by: self.class.name,
          sidekiq_class: msg["class"]
        }
      )
    rescue StandardError => record_error
      Rails.logger.warn(
        "[sidekiq] #{self.class.name} failed to record deprovisioned failure: " \
        "#{record_error.class}: #{record_error.message}"
      )
    end
  end
end
