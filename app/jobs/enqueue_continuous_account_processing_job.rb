class EnqueueContinuousAccountProcessingJob < ApplicationJob
  queue_as :sync

  def perform(limit: 100)
    cap = limit.to_i.clamp(1, 500)
    enqueued = 0
    now = Time.current

    InstagramAccount.where(continuous_processing_enabled: true).order(:id).limit(cap).find_each do |account|
      next if account.cookies.blank?
      next if account.continuous_processing_retry_after_at.present? && account.continuous_processing_retry_after_at > now

      ProcessInstagramAccountContinuouslyJob.perform_later(
        instagram_account_id: account.id,
        trigger_source: "scheduler"
      )
      enqueued += 1
    rescue StandardError => e
      Ops::StructuredLogger.warn(
        event: "continuous_processing.enqueue_failed",
        payload: {
          account_id: account.id,
          error_class: e.class.name,
          error_message: e.message
        }
      )
    end

    Ops::StructuredLogger.info(
      event: "continuous_processing.batch_enqueued",
      payload: {
        limit: cap,
        enqueued_count: enqueued
      }
    )

    { enqueued: enqueued, limit: cap }
  end
end
