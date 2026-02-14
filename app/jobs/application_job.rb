require "json"

class ApplicationJob < ActiveJob::Base
  # Automatically retry jobs that encountered a deadlock
  # retry_on ActiveRecord::Deadlocked

  # Most jobs are safe to ignore if the underlying records are no longer available
  # discard_on ActiveJob::DeserializationError

  around_perform do |job, block|
    block.call
  rescue StandardError => e
    begin
      context = Jobs::ContextExtractor.from_active_job_arguments(job.arguments)
      queue_adapter = Rails.application.config.active_job.queue_adapter.to_s
      solid_id =
        begin
          if queue_adapter == "solid_queue"
            SolidQueue::Job.find_by(active_job_id: job.job_id)&.id
          end
        rescue StandardError
          nil
        end

      BackgroundJobFailure.create!(
        active_job_id: job.job_id,
        queue_name: job.queue_name,
        job_class: job.class.name,
        arguments_json: safe_json(job.arguments),
        provider_job_id: job.provider_job_id,
        solid_queue_job_id: solid_id,
        instagram_account_id: context[:instagram_account_id],
        instagram_profile_id: context[:instagram_profile_id],
        error_class: e.class.name,
        error_message: e.message.to_s,
        backtrace: Array(e.backtrace).join("\n"),
        occurred_at: Time.current,
        metadata: {
          queue_backend: queue_adapter,
          instagram_account_id: context[:instagram_account_id],
          instagram_profile_id: context[:instagram_profile_id],
          job_scope: context[:job_scope],
          context_label: context[:context_label],
          locale: job.locale,
          timezone: job.timezone,
          executions: job.executions,
          exception_executions: job.exception_executions
        }
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
end
