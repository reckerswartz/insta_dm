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

        Sidekiq::Queue.all.each(&:clear)
        Sidekiq::ScheduledSet.new.clear
        Sidekiq::RetrySet.new.clear
        Sidekiq::DeadSet.new.clear

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
