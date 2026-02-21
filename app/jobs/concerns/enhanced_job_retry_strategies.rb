# Enhanced Job Retry Strategies for Improved Reliability
#
# This module provides advanced retry strategies with exponential backoff,
# jitter, and intelligent failure categorization to improve job reliability.

module EnhancedJobRetryStrategies
  extend ActiveSupport::Concern

  # Enhanced retry configuration with jitter
  RETRY_CONFIGS = {
    # Network-related errors - shorter intervals with jitter
    network_errors: {
      base_interval: 5,
      max_interval: 300,
      multiplier: 2.0,
      jitter: 0.1,
      max_attempts: 5
    },
    
    # Database connection errors - moderate intervals
    database_errors: {
      base_interval: 10,
      max_interval: 600,
      multiplier: 1.5,
      jitter: 0.2,
      max_attempts: 4
    },
    
    # AI service errors - longer intervals for service recovery
    ai_service_errors: {
      base_interval: 30,
      max_interval: 1800,
      multiplier: 2.5,
      jitter: 0.3,
      max_attempts: 3
    },
    
    # Resource constraint errors - progressive backoff
    resource_errors: {
      base_interval: 60,
      max_interval: 3600,
      multiplier: 3.0,
      jitter: 0.25,
      max_attempts: 6
    }
  }.freeze

  included do
    # Apply enhanced retry strategies based on error categories
    retry_on Net::ReadTimeout, Net::OpenTimeout, wait: :exponentially_longer, attempts: 5 do |job, error|
      handle_network_retry(job, error)
    end
    
    retry_on Errno::ECONNRESET, Errno::ECONNREFUSED, wait: :exponentially_longer, attempts: 5 do |job, error|
      handle_network_retry(job, error)
    end
    
    retry_on ActiveRecord::ConnectionTimeoutError, wait: :exponentially_longer, attempts: 4 do |job, error|
      handle_database_retry(job, error)
    end
    
    retry_on ActiveRecord::LockWaitTimeout, wait: 2.seconds, attempts: 3 do |job, error|
      handle_database_retry(job, error)
    end
    
    # AI service specific retries
    retry_on Timeout::Error, wait: :exponentially_longer, attempts: 3 do |job, error|
      handle_ai_service_retry(job, error)
    end
  end

  class_methods do
    # Calculate retry delay with jitter
    def calculate_retry_delay(attempt, error_type)
      config = RETRY_CONFIGS[error_type] || RETRY_CONFIGS[:network_errors]
      
      # Exponential backoff with jitter
      delay = config[:base_interval] * (config[:multiplier] ** (attempt - 1))
      delay = [delay, config[:max_interval]].min
      
      # Add jitter to prevent thundering herd
      jitter_range = delay * config[:jitter]
      delay + (rand * jitter_range * 2 - jitter_range)
    end

    # Categorize error for appropriate retry strategy
    def categorize_error(error)
      case error
      when Net::ReadTimeout, Net::OpenTimeout, Errno::ECONNRESET, Errno::ECONNREFUSED
        :network_errors
      when ActiveRecord::ConnectionTimeoutError, ActiveRecord::LockWaitTimeout
        :database_errors
      when Timeout::Error
        :ai_service_errors
      when StandardError
        if error.message.to_s.include?("resource") || error.message.to_s.include?("capacity")
          :resource_errors
        else
          :network_errors
        end
      else
        :network_errors
      end
    end

    # Check if job should be retried based on failure patterns
    def should_retry_job?(job_class, error_class, attempt_count)
      # Don't retry if too many attempts
      return false if attempt_count >= 10
      
      # Don't retry certain error classes
      non_retryable_errors = [
        ActiveRecord::RecordNotFound,
        ActiveRecord::RecordNotUnique,
        Instagram::AuthenticationRequiredError
      ]
      
      !non_retryable_errors.any? { |klass| error_class <= klass }
    end
  end

  private

  def handle_network_retry(job, error)
    attempt = job.executions.to_i
    delay = self.class.calculate_retry_delay(attempt, :network_errors)
    
    Ops::StructuredLogger.warn(
      event: "job.network_retry",
      payload: {
        job_class: job.class.name,
        attempt: attempt,
        delay_seconds: delay.round(2),
        error_class: error.class.name,
        error_message: error.message.byteslice(0, 200)
      }
    )
    
    # ActiveJob/Sidekiq already handles delayed retry scheduling.
    # Never sleep inside workers: it blocks concurrency and causes queue starvation.
  end

  def handle_database_retry(job, error)
    attempt = job.executions.to_i
    delay = self.class.calculate_retry_delay(attempt, :database_errors)
    
    Ops::StructuredLogger.warn(
      event: "job.database_retry",
      payload: {
        job_class: job.class.name,
        attempt: attempt,
        delay_seconds: delay.round(2),
        error_class: error.class.name,
        error_message: error.message.byteslice(0, 200)
      }
    )
    
    # ActiveJob/Sidekiq already handles delayed retry scheduling.
    # Never sleep inside workers: it blocks concurrency and causes queue starvation.
  end

  def handle_ai_service_retry(job, error)
    attempt = job.executions.to_i
    delay = self.class.calculate_retry_delay(attempt, :ai_service_errors)
    
    Ops::StructuredLogger.warn(
      event: "job.ai_service_retry",
      payload: {
        job_class: job.class.name,
        attempt: attempt,
        delay_seconds: delay.round(2),
        error_class: error.class.name,
        error_message: error.message.byteslice(0, 200)
      }
    )
    
    # ActiveJob/Sidekiq already handles delayed retry scheduling.
    # Never sleep inside workers: it blocks concurrency and causes queue starvation.
  end
end
