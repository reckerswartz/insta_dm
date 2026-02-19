class RefreshAccountAuditLogsJob < ApplicationJob
  queue_as :maintenance

  THROTTLE_SECONDS = 2.0
  THROTTLE_EXPIRY = 30.seconds

  def self.enqueue_for(instagram_account_id:, limit: 120)
    account_id = instagram_account_id.to_i
    return if account_id <= 0

    now = Time.current.to_f
    key = throttle_key(account_id)
    last_enqueued = Rails.cache.read(key).to_f
    return if last_enqueued.positive? && (now - last_enqueued) < THROTTLE_SECONDS

    Rails.cache.write(key, now, expires_in: THROTTLE_EXPIRY)
    perform_later(instagram_account_id: account_id, limit: limit)
  rescue StandardError
    perform_later(instagram_account_id: account_id, limit: limit)
  end

  def perform(instagram_account_id:, limit: 120)
    account = InstagramAccount.find_by(id: instagram_account_id)
    return unless account

    entries = Ops::AuditLogBuilder.for_account(instagram_account: account, limit: limit.to_i.clamp(20, 250))
    Turbo::StreamsChannel.broadcast_replace_to(
      account,
      target: "account_audit_logs_section",
      partial: "instagram_accounts/audit_logs_section",
      locals: { recent_audit_entries: entries }
    )
  rescue StandardError => e
    Rails.logger.warn("[RefreshAccountAuditLogsJob] failed for account_id=#{instagram_account_id}: #{e.class}: #{e.message}")
    nil
  end

  def self.throttle_key(account_id)
    "jobs:refresh_account_audit_logs:last_enqueued:#{account_id}"
  end
  private_class_method :throttle_key
end
