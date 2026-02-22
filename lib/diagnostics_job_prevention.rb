# Removes diagnostic/test jobs from Sidekiq queues in production.
class DiagnosticsJobPrevention
  class << self
    def prevent_test_jobs_in_production!
      return unless Rails.env.production?

      require "sidekiq/api"

      Sidekiq::Queue.all.each do |queue|
        queue.each do |job|
          next unless diagnostic_or_test_job?(job.klass)

          puts "Removing test job #{job.klass} from queue #{queue.name}"
          job.delete
        end
      end

      Sidekiq::RetrySet.new.each do |job|
        next unless job.item["error_message"]&.include?("Diagnostics::")

        puts "Removing test job #{job.klass} from retry set"
        job.delete
      end
    end

    private

    def diagnostic_or_test_job?(klass_name)
      klass_name.include?("Diagnostics::") || klass_name.include?("Test")
    end
  end
end
