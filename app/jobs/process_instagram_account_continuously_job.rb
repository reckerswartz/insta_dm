class ProcessInstagramAccountContinuouslyJob < ApplicationJob
  queue_as :sync

  RUNNING_STALE_AFTER = 15.minutes

  retry_on Net::OpenTimeout, Net::ReadTimeout, wait: :polynomially_longer, attempts: 4
  retry_on Errno::ECONNREFUSED, Errno::ECONNRESET, wait: :polynomially_longer, attempts: 4

  def perform(instagram_account_id:, trigger_source: "scheduler")
    account = InstagramAccount.find(instagram_account_id)
    return unless account.continuous_processing_enabled?

    if retry_backoff_active?(account)
      Ops::StructuredLogger.info(
        event: "continuous_processing.skipped_retry_backoff",
        payload: {
          account_id: account.id,
          retry_after_at: account.continuous_processing_retry_after_at&.iso8601,
          trigger_source: trigger_source
        }
      )
      return
    end

    acquired = claim_processing_lock!(account: account, trigger_source: trigger_source)
    return unless acquired

    run = account.sync_runs.create!(
      kind: "continuous_processing",
      status: "running",
      started_at: Time.current,
      stats: {
        trigger_source: trigger_source,
        pipeline_version: "continuous_processing_v1"
      }
    )

    stats = Pipeline::AccountProcessingCoordinator.new(
      account: account,
      trigger_source: trigger_source
    ).run!

    run.update!(
      status: "succeeded",
      finished_at: Time.current,
      stats: (run.stats || {}).merge(stats).merge(status: "succeeded")
    )

    account.update!(
      continuous_processing_state: "idle",
      continuous_processing_last_finished_at: Time.current,
      continuous_processing_last_heartbeat_at: Time.current,
      continuous_processing_last_error: nil,
      continuous_processing_failure_count: 0,
      continuous_processing_retry_after_at: nil
    )

    Ops::StructuredLogger.info(
      event: "continuous_processing.completed",
      payload: {
        account_id: account.id,
        sync_run_id: run.id,
        trigger_source: trigger_source,
        enqueued_jobs: Array(stats[:enqueued_jobs]).size,
        skipped_jobs: Array(stats[:skipped_jobs]).size
      }
    )
  rescue StandardError => e
    handle_failure!(
      account: account,
      run: run,
      error: e,
      trigger_source: trigger_source,
      instagram_account_id: instagram_account_id
    )
    raise
  end

  private

  def retry_backoff_active?(account)
    account.continuous_processing_retry_after_at.present? && account.continuous_processing_retry_after_at > Time.current
  end

  def claim_processing_lock!(account:, trigger_source:)
    claimed = false

    account.with_lock do
      stale = account.continuous_processing_last_heartbeat_at.blank? || account.continuous_processing_last_heartbeat_at < RUNNING_STALE_AFTER.ago

      if account.continuous_processing_state == "running" && !stale
        Ops::StructuredLogger.info(
          event: "continuous_processing.skipped_already_running",
          payload: {
            account_id: account.id,
            trigger_source: trigger_source,
            last_heartbeat_at: account.continuous_processing_last_heartbeat_at&.iso8601
          }
        )
        next
      end

      account.update!(
        continuous_processing_state: "running",
        continuous_processing_last_started_at: Time.current,
        continuous_processing_last_heartbeat_at: Time.current,
        continuous_processing_last_error: nil
      )

      claimed = true
    end

    claimed
  end

  def handle_failure!(account:, run:, error:, trigger_source:, instagram_account_id:)
    account ||= InstagramAccount.where(id: instagram_account_id).first

    return unless account

    account.with_lock do
      failures = account.continuous_processing_failure_count.to_i + 1
      retry_after = Time.current + failure_backoff_for(failures)

      account.update!(
        continuous_processing_state: "idle",
        continuous_processing_last_finished_at: Time.current,
        continuous_processing_last_heartbeat_at: Time.current,
        continuous_processing_last_error: "#{error.class}: #{error.message}",
        continuous_processing_failure_count: failures,
        continuous_processing_retry_after_at: retry_after
      )
    end

    run&.update!(
      status: "failed",
      finished_at: Time.current,
      error_message: error.message,
      stats: (run.stats || {}).merge(
        status: "failed",
        error_class: error.class.name,
        error_message: error.message
      )
    )

    Ops::StructuredLogger.error(
      event: "continuous_processing.failed",
      payload: {
        account_id: account.id,
        sync_run_id: run&.id,
        trigger_source: trigger_source,
        error_class: error.class.name,
        error_message: error.message,
        retry_after_at: account.continuous_processing_retry_after_at&.iso8601,
        failure_count: account.continuous_processing_failure_count
      }
    )
  end

  def failure_backoff_for(failure_count)
    base =
      case failure_count
      when 1 then 5.minutes
      when 2 then 15.minutes
      when 3 then 30.minutes
      when 4 then 1.hour
      else 3.hours
      end

    base + rand(0..90).seconds
  end
end
