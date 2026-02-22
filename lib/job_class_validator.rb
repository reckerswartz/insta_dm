# Preventive guard for background jobs
#
# Ensures any class attempting to enqueue through `perform_later`
# is a valid ApplicationJob descendant.
module JobClassValidator
  extend ActiveSupport::Concern

  class_methods do
    def perform_later(*args)
      validate_job_class!
      super
    end

    private

    def validate_job_class!
      return if name.present? && ancestors.include?(ApplicationJob)

      raise ArgumentError, "Invalid job class: #{name}"
    end
  end
end
