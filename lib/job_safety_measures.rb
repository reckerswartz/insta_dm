# Preventive measures for background job failures

require 'active_support/concern'

# 1. Add job class validation before enqueue
module JobClassValidator
  extend ActiveSupport::Concern

  class_methods do
    def perform_later(*args)
      validate_job_class!
      super(*args)
    end

    private

    def validate_job_class!
      # Ensure the job class exists and is properly defined
      unless name.present? && ancestors.include?(ApplicationJob)
        raise ArgumentError, "Invalid job class: #{name}"
      end
    end
  end
end

# 2. Add retry configuration for test jobs that shouldn't persist
class DiagnosticsJobPrevention
  def self.prevent_test_jobs_in_production!
    return unless Rails.env.production?

    # Clear any test diagnostic jobs from queues
    require 'sidekiq/api'
    
    Sidekiq::Queue.all.each do |queue|
      queue.each do |job|
        if job.klass.include?('Diagnostics::') || job.klass.include?('Test')
          puts "Removing test job #{job.klass} from queue #{queue.name}"
          job.delete
        end
      end
    end

    Sidekiq::RetrySet.new.each do |job|
      if job.item['error_message']&.include?('Diagnostics::')
        puts "Removing test job #{job.klass} from retry set"
        job.delete
      end
    end
  end
end
