module Ops
  class QueueHealth
    STUCK_BACKLOG_THRESHOLD = 1

    def self.check!
      counts = Ops::Metrics.queue_counts
      return { ok: true, backend: counts[:backend].to_s } unless counts[:backend].to_s == "sidekiq"

      enqueued = counts[:enqueued].to_i
      scheduled = counts[:scheduled].to_i
      retries = counts[:retries].to_i
      dead = counts[:dead].to_i
      processes = counts[:processes].to_i

      no_worker_with_backlog = processes.zero? && (enqueued + scheduled + retries) >= STUCK_BACKLOG_THRESHOLD

      if no_worker_with_backlog
        message = "No Sidekiq workers detected while queue backlog is present."
        Ops::IssueTracker.record_queue_health!(
          ok: false,
          message: message,
          metadata: counts
        )
        Ops::StructuredLogger.error(event: "queue.health.failed", payload: counts.merge(message: message))
        return { ok: false, reason: "no_workers_with_backlog", counts: counts }
      end

      if dead.positive?
        Ops::StructuredLogger.warn(
          event: "queue.health.dead_jobs_present",
          payload: counts
        )
      end

      Ops::IssueTracker.record_queue_health!(
        ok: true,
        message: "Sidekiq queue healthy.",
        metadata: counts
      )
      { ok: true, counts: counts }
    rescue StandardError => e
      Ops::StructuredLogger.error(
        event: "queue.health.check_failed",
        payload: { error_class: e.class.name, error_message: e.message }
      )
      { ok: false, reason: "check_failed", error_class: e.class.name, error_message: e.message }
    end
  end
end
