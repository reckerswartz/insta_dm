module Admin
  module BackgroundJobs
    class DashboardSnapshot
      Snapshot = Struct.new(:backend, :counts, :processes, :recent_jobs, :recent_failed, keyword_init: true)

      def initialize(backend:, serializer: Admin::BackgroundJobs::JobSerializer.new)
        @backend = backend.to_s
        @serializer = serializer
      end

      def call
        return sidekiq_snapshot if backend == "sidekiq"

        solid_queue_snapshot
      end

      private

      attr_reader :backend, :serializer

      def solid_queue_snapshot
        counts = {
          ready: safe_count { SolidQueue::ReadyExecution.count },
          scheduled: safe_count { SolidQueue::ScheduledExecution.count },
          claimed: safe_count { SolidQueue::ClaimedExecution.count },
          blocked: safe_count { SolidQueue::BlockedExecution.count },
          failed: safe_count { SolidQueue::FailedExecution.count },
          pauses: safe_count { SolidQueue::Pause.count },
          jobs_total: safe_count { SolidQueue::Job.count }
        }

        processes = safe_query { SolidQueue::Process.order(last_heartbeat_at: :desc).limit(50).to_a } || []
        solid_jobs = safe_query { SolidQueue::Job.order(created_at: :desc).limit(100).to_a } || []
        recent_jobs = solid_jobs.map { |job| serializer.serialize_solid_queue(job) }
        recent_failed = safe_query do
          SolidQueue::FailedExecution
            .includes(:job)
            .order(created_at: :desc)
            .limit(50)
            .to_a
        end || []

        Snapshot.new(
          backend: backend,
          counts: counts,
          processes: processes,
          recent_jobs: recent_jobs,
          recent_failed: recent_failed
        )
      end

      def sidekiq_snapshot
        require "sidekiq/api"

        queues = safe_query { Sidekiq::Queue.all } || []
        scheduled = Sidekiq::ScheduledSet.new
        retries = Sidekiq::RetrySet.new
        dead = Sidekiq::DeadSet.new
        processes = Sidekiq::ProcessSet.new

        queue_rows = queues.map { |queue| { name: queue.name, size: queue.size } }
        counts = {
          enqueued: queue_rows.sum { |row| row[:size].to_i },
          scheduled: safe_count { scheduled.size },
          retries: safe_count { retries.size },
          dead: safe_count { dead.size },
          processes: safe_count { processes.size },
          queues: queue_rows
        }

        serialized_processes = safe_query do
          processes.map do |process|
            {
              identity: process["identity"],
              hostname: process["hostname"],
              pid: process["pid"],
              queues: Array(process["queues"]),
              labels: Array(process["labels"]),
              busy: process["busy"].to_i,
              beat: serializer.parse_epoch_time(process["beat"])
            }
          end.sort_by { |row| row[:beat] || Time.at(0) }.reverse.first(50)
        end || []

        enqueued_rows = queues.flat_map do |queue|
          queue.first(30).map { |job| serializer.serialize_sidekiq(job: job, status: "enqueued", queue_name: queue.name) }
        end
        scheduled_rows = scheduled.first(30).map { |job| serializer.serialize_sidekiq(job: job, status: "scheduled", queue_name: job.queue) }
        retry_rows = retries.first(20).map { |job| serializer.serialize_sidekiq(job: job, status: "retry", queue_name: job.queue) }
        dead_rows = dead.first(20).map { |job| serializer.serialize_sidekiq(job: job, status: "dead", queue_name: job.queue) }

        recent_jobs = (enqueued_rows + scheduled_rows + retry_rows + dead_rows)
          .sort_by { |row| row[:created_at] || Time.at(0) }
          .reverse
          .first(100)

        Snapshot.new(
          backend: backend,
          counts: counts,
          processes: serialized_processes,
          recent_jobs: recent_jobs,
          recent_failed: (retry_rows + dead_rows).first(50)
        )
      rescue StandardError
        Snapshot.new(
          backend: backend,
          counts: { enqueued: 0, scheduled: 0, retries: 0, dead: 0, processes: 0, queues: [] },
          processes: [],
          recent_jobs: [],
          recent_failed: []
        )
      end

      def safe_count
        yield
      rescue StandardError
        0
      end

      def safe_query
        yield
      rescue StandardError
        nil
      end
    end
  end
end
