require "json"
require_dependency "scheduled_account_batching"

class ApplicationJob < ActiveJob::Base
  include JobRetryPolicy
  include JobSafetyImprovements
  include JobIdempotency
  # Automatically retry jobs that encountered a deadlock
  # retry_on ActiveRecord::Deadlocked

  # Most jobs are safe to ignore if the underlying records are no longer available
  # discard_on ActiveJob::DeserializationError

  discard_on Instagram::AuthenticationRequiredError do |job, error|
    context = Jobs::ContextExtractor.from_active_job_arguments(job.arguments)
    job.send(:apply_auth_backoff!, context: context, error: error)

    Rails.logger.warn(
      "[jobs.auth_required] #{job.class.name} discarded: #{error.message} " \
      "(account_id=#{context[:instagram_account_id] || '-'}, profile_id=#{context[:instagram_profile_id] || '-'})"
    )

    Ops::LiveUpdateBroadcaster.broadcast!(
      topic: "jobs_changed",
      account_id: context[:instagram_account_id],
      payload: {
        status: "discarded",
        reason: "authentication_required",
        job_class: job.class.name,
        instagram_account_id: context[:instagram_account_id],
        instagram_profile_id: context[:instagram_profile_id],
        instagram_profile_post_id: context[:instagram_profile_post_id]
      },
      throttle_key: "jobs_changed"
    )
  end

  discard_on ActiveRecord::RecordNotUnique

  discard_on ActiveRecord::RecordNotFound do |job, error|
    context = Jobs::ContextExtractor.from_active_job_arguments(job.arguments)
    Ops::StructuredLogger.warn(
      event: "job.record_not_found_discarded",
      payload: {
        job_class: job.class.name,
        error_message: error.message,
        instagram_account_id: context[:instagram_account_id],
        instagram_profile_id: context[:instagram_profile_id],
        instagram_profile_post_id: context[:instagram_profile_post_id]
      }
    )
  end

  around_perform do |job, block|
    context = Jobs::ContextExtractor.from_active_job_arguments(job.arguments)
    started_at = Time.current
    started_monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC) rescue nil

    Current.set(
      active_job_id: job.job_id,
      provider_job_id: job.provider_job_id,
      job_class: job.class.name,
      queue_name: job.queue_name,
      instagram_account_id: context[:instagram_account_id],
      instagram_profile_id: context[:instagram_profile_id]
    ) do
      Ai::ApiUsageTracker.with_context(
        active_job_id: job.job_id,
        provider_job_id: job.provider_job_id,
        job_class: job.class.name,
        queue_name: job.queue_name,
        instagram_account_id: context[:instagram_account_id],
        instagram_profile_id: context[:instagram_profile_id]
      ) do
        Ops::StructuredLogger.info(
          event: "job.started",
          payload: {
            active_job_id: job.job_id,
            job_class: job.class.name,
            queue_name: job.queue_name,
            instagram_account_id: context[:instagram_account_id],
            instagram_profile_id: context[:instagram_profile_id]
          }
        )

        Ops::LiveUpdateBroadcaster.broadcast!(
          topic: "jobs_changed",
          account_id: context[:instagram_account_id],
          payload: {
            status: "started",
            job_class: job.class.name,
            active_job_id: job.job_id,
            instagram_account_id: context[:instagram_account_id],
            instagram_profile_id: context[:instagram_profile_id],
            instagram_profile_post_id: context[:instagram_profile_post_id]
          },
          throttle_key: "jobs_changed"
        )

        block.call

        duration_ms =
          if started_monotonic
            ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_monotonic) * 1000).round
          end

        Ops::StructuredLogger.info(
          event: "job.completed",
          payload: {
            active_job_id: job.job_id,
            job_class: job.class.name,
            queue_name: job.queue_name,
            instagram_account_id: context[:instagram_account_id],
            instagram_profile_id: context[:instagram_profile_id],
            duration_ms: duration_ms
          }
        )

        Ops::LiveUpdateBroadcaster.broadcast!(
          topic: "jobs_changed",
          account_id: context[:instagram_account_id],
          payload: {
            status: "completed",
            job_class: job.class.name,
            active_job_id: job.job_id,
            instagram_account_id: context[:instagram_account_id],
            instagram_profile_id: context[:instagram_profile_id],
            instagram_profile_post_id: context[:instagram_profile_post_id]
          },
          throttle_key: "jobs_changed"
        )
      end
    end
  rescue StandardError => e
    begin
      queue_adapter = Rails.application.config.active_job.queue_adapter.to_s
      solid_id =
        begin
          if queue_adapter == "solid_queue"
            SolidQueue::Job.find_by(active_job_id: job.job_id)&.id
          end
        rescue StandardError
          nil
        end

      failure = BackgroundJobFailure.create!(
        active_job_id: job.job_id,
        queue_name: job.queue_name,
        job_class: job.class.name,
        arguments_json: job.send(:safe_json, job.arguments),
        provider_job_id: job.provider_job_id,
        solid_queue_job_id: solid_id,
        instagram_account_id: context[:instagram_account_id],
        instagram_profile_id: context[:instagram_profile_id],
        error_class: e.class.name,
        error_message: e.message.to_s,
        backtrace: Array(e.backtrace).join("\n"),
        failure_kind: job.send(:failure_kind_for, e),
        retryable: job.send(:retryable_for, e),
        occurred_at: Time.current,
        metadata: {
          queue_backend: queue_adapter,
          instagram_account_id: context[:instagram_account_id],
          instagram_profile_id: context[:instagram_profile_id],
          job_scope: context[:job_scope],
          context_label: context[:context_label],
          started_at: started_at&.iso8601,
          failed_at: Time.current.iso8601,
          duration_ms: ((Time.current - started_at) * 1000).round,
          locale: job.locale,
          timezone: job.timezone,
          executions: job.executions,
          exception_executions: job.exception_executions,
          failure_classification: job.send(:failure_classification_for, e),
          manual_review_required: job.send(:manual_review_required_for, e)
        }
      )

      Ops::IssueTracker.record_job_failure!(
        job: job,
        exception: e,
        context: context,
        failure_record: failure
      )

      Ops::StructuredLogger.error(
        event: "job.failed",
        payload: {
          active_job_id: job.job_id,
          job_class: job.class.name,
          queue_name: job.queue_name,
          instagram_account_id: context[:instagram_account_id],
          instagram_profile_id: context[:instagram_profile_id],
          error_class: e.class.name,
          error_message: e.message,
          failure_kind: failure.failure_kind,
          retryable: failure.retryable?
        }
      )

      Ops::LiveUpdateBroadcaster.broadcast!(
        topic: "jobs_changed",
        account_id: context[:instagram_account_id],
        payload: {
          status: "failed",
          job_class: job.class.name,
          active_job_id: job.job_id,
          failure_kind: failure.failure_kind,
          instagram_account_id: context[:instagram_account_id],
          instagram_profile_id: context[:instagram_profile_id],
          instagram_profile_post_id: context[:instagram_profile_post_id]
        },
        throttle_key: "jobs_changed"
      )
    rescue StandardError
      # Never let failure logging take down job execution error reporting.
      nil
    end

    raise
  end

  private

  def safe_json(value)
    JSON.generate(value)
  rescue StandardError => e
    JSON.generate({ error: "unable_to_serialize_arguments", original_error: e.class.name })
  end

  def failure_kind_for(error)
    return "authentication" if authentication_error?(error)
    return "transient" if transient_error?(error)

    "runtime"
  end

  def retryable_for(error)
    return false if authentication_error?(error)
    return false if manual_review_required_for(error)
    return false if non_recoverable_error?(error)
    return true if transient_error?(error)

    false
  end

  def transient_error?(error)
    classes = [
      "Net::OpenTimeout",
      "Net::ReadTimeout",
      "Errno::ECONNRESET",
      "Errno::ECONNREFUSED",
      "Selenium::WebDriver::Error::TimeoutError",
      "Timeout::Error",
      "ActiveRecord::ConnectionTimeoutError",
      "ActiveRecord::LockWaitTimeout",
      "ActiveRecord::Deadlocked"
    ].filter_map(&:safe_constantize)
    classes.any? { |klass| error.is_a?(klass) }
  rescue StandardError
    false
  end

  def non_recoverable_error?(error)
    non_recoverable_classes = [
      ActiveRecord::RecordNotFound,
      ActiveRecord::RecordInvalid,
      ActiveRecord::RecordNotUnique,
      ActiveJob::DeserializationError,
      ArgumentError
    ]
    return true if non_recoverable_classes.any? { |klass| error.is_a?(klass) }

    message = error.message.to_s.downcase
    return true if message.include?("invalid payload")
    return true if message.include?("invalid parameter")
    return true if message.include?("validation failed")
    return true if message.include?("media missing")
    return true if message.include?("deleted media")
    return true if message.include?("404")
    return true if message.include?("permission denied")
    return true if message.include?("forbidden")
    return true if message.include?("unsupported media")

    false
  rescue StandardError
    false
  end

  def manual_review_required_for(error)
    classes = [
      NoMethodError,
      NameError,
      TypeError,
      SyntaxError
    ]
    return true if classes.any? { |klass| error.is_a?(klass) }

    message = error.message.to_s.downcase
    return true if message.include?("undefined method")
    return true if message.include?("stack level too deep")

    false
  rescue StandardError
    false
  end

  def failure_classification_for(error)
    return "non_recoverable" if authentication_error?(error)
    return "manual_review_required" if manual_review_required_for(error)
    return "recoverable" if transient_error?(error)
    return "non_recoverable" if non_recoverable_error?(error)

    "non_recoverable"
  rescue StandardError
    "non_recoverable"
  end

  def authentication_error?(error)
    return true if error.is_a?(Instagram::AuthenticationRequiredError)

    msg = error.message.to_s.downcase
    msg.include?("stored cookies are not authenticated") ||
      msg.include?("authentication required") ||
      msg.include?("no stored cookies")
  end

  def apply_auth_backoff!(context:, error:)
    account_id = context[:instagram_account_id]
    return if account_id.blank?

    account = InstagramAccount.find_by(id: account_id)
    return unless account

    account.with_lock do
      next_retry_at = [ account.continuous_processing_retry_after_at, 2.hours.from_now ].compact.max
      account.update!(
        continuous_processing_state: "idle",
        continuous_processing_last_error: "#{error.class}: #{error.message}",
        continuous_processing_failure_count: account.continuous_processing_failure_count.to_i + 1,
        continuous_processing_retry_after_at: next_retry_at
      )
    end
  rescue StandardError
    nil
  end
end
