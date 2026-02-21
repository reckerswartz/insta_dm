# Job Idempotency and Deduplication Utilities
#
# This module provides utilities for making jobs idempotent and preventing duplicate executions

module JobIdempotency
  extend ActiveSupport::Concern

  class_methods do
    # Enqueue job with deduplication
    def perform_later_with_deduplication(*args, **kwargs)
      deduplication_key = generate_deduplication_key(args, kwargs)
      
      # Check if job is already queued or running
      if job_already_enqueued?(deduplication_key)
        Rails.logger.info("[JobIdempotency] Skipping duplicate job: #{name} with key #{deduplication_key}")
        return nil
      end

      # Mark job as enqueued
      mark_job_enqueued!(deduplication_key)
      
      # Enqueue the job with cleanup callback
      job = perform_later(*args, **kwargs)
      
      # Store deduplication info for cleanup
      store_job_deduplication_info(job.job_id, deduplication_key)
      
      job
    rescue StandardError => e
      # Clean up deduplication marker on error
      clear_job_enqueued!(deduplication_key)
      raise
    end

    # Schedule job with deduplication
    def set_with_deduplication(wait:, **kwargs)
      deduplication_key = generate_deduplication_key([], kwargs)
      
      if job_already_enqueued?(deduplication_key)
        Rails.logger.info("[JobIdempotency] Skipping duplicate scheduled job: #{name} with key #{deduplication_key}")
        return nil
      end

      mark_job_enqueued!(deduplication_key)
      job = set(wait: wait).perform_later(**kwargs)
      store_job_deduplication_info(job.job_id, deduplication_key)
      
      job
    rescue StandardError => e
      clear_job_enqueued!(deduplication_key)
      raise
    end

    private

    def generate_deduplication_key(args, kwargs)
      # Create a deterministic key based on job class and arguments
      key_parts = [name.to_s]
      
      # Add positional arguments
      args.each { |arg| key_parts << normalize_argument(arg) }
      
      # Add keyword arguments (sorted for consistency)
      kwargs.sort.each { |k, v| key_parts << "#{k}=#{normalize_argument(v)}" }
      
      Digest::SHA256.hexdigest(key_parts.join("|"))
    end

    def normalize_argument(arg)
      case arg
      when Integer, String, Symbol, TrueClass, FalseClass, NilClass
        arg.to_s
      when Array
        "[#{arg.map { |a| normalize_argument(a) }.join(',')}]"
      when Hash
        "{#{arg.sort.map { |k, v| "#{k}=#{normalize_argument(v)}" }.join(',')}"
      when ActiveRecord::Base
        "#{arg.class.name}_#{arg.id}"
      else
        arg.class.name
      end
    rescue StandardError
      "unknown"
    end

    def job_already_enqueued?(deduplication_key)
      cache_key = "job_deduplication:#{deduplication_key}"
      Rails.cache.exist?(cache_key)
    end

    def mark_job_enqueued!(deduplication_key)
      cache_key = "job_deduplication:#{deduplication_key}"
      # Store for 1 hour to prevent immediate re-enqueue
      Rails.cache.write(cache_key, true, expires_in: 1.hour)
    end

    def clear_job_enqueued!(deduplication_key)
      cache_key = "job_deduplication:#{deduplication_key}"
      Rails.cache.delete(cache_key)
    end

    def store_job_deduplication_info(job_id, deduplication_key)
      cache_key = "job_info:#{job_id}"
      Rails.cache.write(cache_key, deduplication_key, expires_in: 24.hours)
    end
  end

  private

  # Ensure job cleanup on completion
  def perform_with_idempotency(*args, **kwargs)
    deduplication_key = retrieve_deduplication_key
    
    begin
      yield(*args, **kwargs)
    ensure
      # Clean up deduplication markers
      clear_deduplication_markers(deduplication_key) if deduplication_key
    end
  end

  def retrieve_deduplication_key
    cache_key = "job_info:#{job_id}"
    Rails.cache.read(cache_key)
  end

  def clear_deduplication_markers(deduplication_key)
    # Clear the main deduplication marker
    cache_key = "job_deduplication:#{deduplication_key}"
    Rails.cache.delete(cache_key)
    
    # Clear the job info marker
    job_info_key = "job_info:#{job_id}"
    Rails.cache.delete(job_info_key)
  end

  # Check if work has already been done
  def work_already_completed?(work_identifier)
    cache_key = "work_completed:#{work_identifier}"
    Rails.cache.exist?(cache_key)
  end

  # Mark work as completed
  def mark_work_completed!(work_identifier, ttl = 1.hour)
    cache_key = "work_completed:#{work_identifier}"
    Rails.cache.write(cache_key, true, expires_in: ttl)
  end

  # Execute work with completion tracking
  def execute_once(work_identifier, ttl: 1.hour)
    if work_already_completed?(work_identifier)
      Rails.logger.info("[JobIdempotency] Work already completed: #{work_identifier}")
      return false
    end

    result = yield
    
    mark_work_completed!(work_identifier, ttl)
    Rails.logger.info("[JobIdempotency] Work completed and marked: #{work_identifier}")
    
    result
  rescue StandardError => e
    Rails.logger.error("[JobIdempotency] Work failed for #{work_identifier}: #{e.class}: #{e.message}")
    raise
  end
end
