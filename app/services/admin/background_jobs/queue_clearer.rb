module Admin
  module BackgroundJobs
    class QueueClearer
      def initialize(backend:)
        @backend = backend.to_s
      end

      def call
        return clear_sidekiq_jobs! if backend == "sidekiq"

        clear_solid_queue_jobs!
      end

      private

      attr_reader :backend

      def clear_sidekiq_jobs!
        require "sidekiq/api"

        Sidekiq::Queue.all.each do |queue|
          queue.each do |entry|
            Ops::BackgroundJobLifecycleRecorder.record_sidekiq_removal(
              entry: entry,
              reason: "admin_clear_queue"
            )
          end
          queue.clear
        end
        [ Sidekiq::ScheduledSet.new, Sidekiq::RetrySet.new, Sidekiq::DeadSet.new ].each do |set|
          set.each do |entry|
            Ops::BackgroundJobLifecycleRecorder.record_sidekiq_removal(
              entry: entry,
              reason: "admin_clear_queue"
            )
          end
          set.clear
        end

        Sidekiq::ProcessSet.new.each do |process|
          process.quiet! if process.alive?
        end
      end

      def clear_solid_queue_jobs!
        SolidQueue::ReadyExecution.delete_all
        SolidQueue::ScheduledExecution.delete_all
        SolidQueue::ClaimedExecution.delete_all
        SolidQueue::BlockedExecution.delete_all
        SolidQueue::FailedExecution.delete_all
        SolidQueue::Job.delete_all

        SolidQueue::Process.delete_all
      end
    end
  end
end
