# frozen_string_literal: true

class SyncInitialAccountAvatarJob < ApplicationJob
  queue_as :avatar_orchestration

  RATE_LIMIT_SECONDS = ENV.fetch("INITIAL_ACCOUNT_AVATAR_SYNC_RATE_LIMIT_SECONDS", "86400").to_i.clamp(1.hour.to_i, 7.days.to_i)
  RATE_LIMIT_CACHE_KEY_PREFIX = "instagram_account:initial_avatar_sync".freeze

  def perform(instagram_account_id:)
    account = InstagramAccount.find_by(id: instagram_account_id)
    return unless account
    return if account.username.to_s.blank?

    reserved_rate_limit = false
    rate_limit = reserve_rate_limit!(account_id: account.id)
    unless rate_limit[:reserved]
      Ops::StructuredLogger.info(
        event: "initial_account_avatar_sync.skipped_rate_limited",
        payload: {
          instagram_account_id: account.id,
          remaining_seconds: rate_limit[:remaining_seconds].to_i
        }
      )
      return
    end
    reserved_rate_limit = true

    profile = account.instagram_profiles.find_or_create_by!(username: account.username)
    action_log = profile.instagram_profile_action_logs.create!(
      instagram_account: account,
      action: "fetch_profile_details",
      status: "queued",
      trigger_source: "account_created_avatar_bootstrap",
      occurred_at: Time.current,
      metadata: {
        requested_by: self.class.name,
        reason: "initial_avatar_sync"
      }
    )
    job = FetchInstagramProfileDetailsJob.perform_later(
      instagram_account_id: account.id,
      instagram_profile_id: profile.id,
      profile_action_log_id: action_log.id
    )
    action_log.update!(active_job_id: job.job_id, queue_name: job.queue_name)
  rescue StandardError
    release_rate_limit!(account_id: instagram_account_id) if reserved_rate_limit
    raise
  end

  private

  def reserve_rate_limit!(account_id:)
    now = Time.current
    payload = {
      "reserved_at" => now.iso8601(3),
      "ttl_seconds" => RATE_LIMIT_SECONDS
    }
    written = rate_limit_store.write(rate_limit_cache_key(account_id), payload, expires_in: RATE_LIMIT_SECONDS.seconds, unless_exist: true)
    return { reserved: true, remaining_seconds: RATE_LIMIT_SECONDS } if ActiveModel::Type::Boolean.new.cast(written)

    existing = rate_limit_store.read(rate_limit_cache_key(account_id))
    {
      reserved: false,
      remaining_seconds: remaining_seconds_from(payload: existing, now: now)
    }
  rescue StandardError
    { reserved: true, remaining_seconds: 0 }
  end

  def release_rate_limit!(account_id:)
    rate_limit_store.delete(rate_limit_cache_key(account_id))
  rescue StandardError
    nil
  end

  def remaining_seconds_from(payload:, now:)
    return 0 unless payload.is_a?(Hash)

    reserved_at = Time.zone.parse(payload["reserved_at"].to_s) rescue nil
    return 0 unless reserved_at

    ttl_seconds = payload["ttl_seconds"].to_i
    ttl_seconds = RATE_LIMIT_SECONDS if ttl_seconds <= 0
    remaining = (reserved_at + ttl_seconds.seconds - now).ceil
    remaining.positive? ? remaining : 0
  rescue StandardError
    0
  end

  def rate_limit_cache_key(account_id)
    "#{RATE_LIMIT_CACHE_KEY_PREFIX}:#{account_id.to_i}"
  end

  def rate_limit_store
    return Rails.cache unless Rails.cache.is_a?(ActiveSupport::Cache::NullStore)

    self.class.instance_variable_get(:@rate_limit_store) ||
      self.class.instance_variable_set(
        :@rate_limit_store,
        ActiveSupport::Cache::MemoryStore.new(expires_in: RATE_LIMIT_SECONDS.seconds)
      )
  rescue StandardError
    Rails.cache
  end
end
