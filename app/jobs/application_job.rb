require "json"

class ApplicationJob < ActiveJob::Base
  # Automatically retry jobs that encountered a deadlock
  # retry_on ActiveRecord::Deadlocked

  # Most jobs are safe to ignore if the underlying records are no longer available
  # discard_on ActiveJob::DeserializationError

  discard_on Instagram::AuthenticationRequiredError do |job, error|
    context = Jobs::ContextExtractor.from_active_job_arguments(job.arguments)
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
          exception_executions: job.exception_executions
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
  rescue StandardError
    JSON.generate({ error: "unable_to_serialize_arguments" })
  end

  def failure_kind_for(error)
    return "authentication" if authentication_error?(error)
    return "transient" if transient_error?(error)

    "runtime"
  end

  def retryable_for(error)
    !authentication_error?(error)
  end

  def transient_error?(error)
    classes = [
      "Net::OpenTimeout",
      "Net::ReadTimeout",
      "Errno::ECONNRESET",
      "Errno::ECONNREFUSED",
      "Selenium::WebDriver::Error::TimeoutError"
    ].filter_map(&:safe_constantize)
    classes.any? { |klass| error.is_a?(klass) }
  rescue StandardError
    false
  end

  def authentication_error?(error)
    return true if error.is_a?(Instagram::AuthenticationRequiredError)

    msg = error.message.to_s.downcase
    msg.include?("stored cookies are not authenticated") ||
      msg.include?("authentication required") ||
      msg.include?("no stored cookies")
  end
end
