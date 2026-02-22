# Job Safety Improvements for Background Job Reliability
#
# This module provides enhanced error handling and safety measures for background jobs
# to prevent cascading failures and improve system reliability.

module JobSafetyImprovements
  extend ActiveSupport::Concern

  class_methods do
    def safe_find_record(klass, id, context = {})
      return nil if id.blank?
      
      record = klass.find_by(id: id)
      unless record
        Ops::StructuredLogger.warn(
          event: "job.record_not_found",
          payload: {
            job_class: name,
            record_class: klass.name,
            record_id: id,
            context: context
          }
        )
      end
      record
    rescue StandardError => e
      Ops::StructuredLogger.error(
        event: "job.record_find_error",
        payload: {
          job_class: name,
          record_class: klass.name,
          record_id: id,
          error_class: e.class.name,
          error_message: e.message,
          context: context
        }
      )
      nil
    end

    def safe_find_chain(parent, association, id, context = {})
      return nil if parent.blank? || id.blank?
      
      record = parent.public_send(association).find_by(id: id)
      unless record
        Ops::StructuredLogger.warn(
          event: "job.association_record_not_found",
          payload: {
            job_class: name,
            parent_class: parent.class.name,
            parent_id: parent.id,
            association: association,
            record_id: id,
            context: context
          }
        )
      end
      record
    rescue StandardError => e
      Ops::StructuredLogger.error(
        event: "job.association_record_find_error",
        payload: {
          job_class: name,
          parent_class: parent.class.name,
          parent_id: parent.id,
          association: association,
          record_id: id,
          error_class: e.class.name,
          error_message: e.message,
          context: context
        }
      )
      nil
    end
  end

  private

  def safe_method_call(object, method_name, *args, **kwargs)
    return nil unless object.respond_to?(method_name, true)
    
    object.public_send(method_name, *args, **kwargs)
  rescue StandardError => e
    Ops::StructuredLogger.error(
      event: "job.method_call_error",
      payload: {
        job_class: self.class.name,
        object_class: object.class.name,
        method_name: method_name,
        error_class: e.class.name,
        error_message: e.message,
        arguments_count: args.length,
        keyword_arguments: kwargs.keys
      }
    )
    raise
  end

  def with_resource_cleanup
    yield
  rescue StandardError => e
    # Cleanup logic can be added here
    raise
  ensure
    # Ensure cleanup happens even on success
    GC.start if rand(100) < 5 # Occasional GC to prevent memory buildup
  end

  def validate_job_arguments!(required_keys, optional_keys = [])
    missing_keys = required_keys.select { |key| arguments_hash[key.to_s].blank? }
    
    if missing_keys.any?
      raise ArgumentError, "Missing required job arguments: #{missing_keys.join(', ')}"
    end
    
    # Log unexpected arguments for debugging
    expected_keys = required_keys + optional_keys
    unexpected_keys = arguments_hash.keys - expected_keys.map(&:to_s)
    
    if unexpected_keys.any?
      Ops::StructuredLogger.warn(
        event: "job.unexpected_arguments",
        payload: {
          job_class: self.class.name,
          unexpected_keys: unexpected_keys,
          expected_keys: expected_keys
        }
      )
    end
  end

  def arguments_hash
    return {} unless arguments.respond_to?(:first)
    
    args = arguments.first
    args.is_a?(Hash) ? args : {}
  rescue StandardError
    {}
  end
end
