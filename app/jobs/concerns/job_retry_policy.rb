module JobRetryPolicy
  extend ActiveSupport::Concern

  included do
    retry_on Net::ReadTimeout, Net::OpenTimeout, wait: :exponentially_longer, attempts: 5 do |job, error|
      job.send(:log_retry_event, category: "network", error: error)
    end

    retry_on Errno::ECONNRESET, Errno::ECONNREFUSED, wait: :exponentially_longer, attempts: 5 do |job, error|
      job.send(:log_retry_event, category: "network", error: error)
    end

    retry_on ActiveRecord::ConnectionTimeoutError, wait: :exponentially_longer, attempts: 4 do |job, error|
      job.send(:log_retry_event, category: "database", error: error)
    end

    retry_on ActiveRecord::LockWaitTimeout, wait: 2.seconds, attempts: 4 do |job, error|
      job.send(:log_retry_event, category: "database", error: error)
    end
  end

  private

  def log_retry_event(category:, error:)
    Ops::StructuredLogger.warn(
      event: "job.retry",
      payload: {
        job_class: self.class.name,
        category: category.to_s,
        attempt: executions.to_i,
        error_class: error.class.name,
        error_message: error.message.to_s.byteslice(0, 200)
      }
    )
  rescue StandardError
    nil
  end
end
