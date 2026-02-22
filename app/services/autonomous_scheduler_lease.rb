require "securerandom"

class AutonomousSchedulerLease
  Reservation = Struct.new(
    :reserved,
    :token,
    :reserved_at,
    :lease_seconds,
    :remaining_seconds,
    :blocked_by,
    keyword_init: true
  )

  DEFAULT_LEASE_SECONDS = ENV.fetch("AUTONOMOUS_SCHEDULER_LEASE_SECONDS", "90").to_i.clamp(30, 900)

  class << self
    def reserve!(account:, source:, lease_seconds: DEFAULT_LEASE_SECONDS, now: Time.current)
      return Reservation.new(reserved: false, lease_seconds: 0, remaining_seconds: 0) if account.blank?

      ttl = lease_seconds.to_i.clamp(15, 1800)
      key = cache_key(account_id: account.id)
      token = SecureRandom.hex(8)
      payload = {
        "token" => token,
        "source" => source.to_s.presence || "unknown",
        "reserved_at" => now.iso8601(3),
        "lease_seconds" => ttl
      }
      written = Rails.cache.write(key, payload, expires_in: ttl.seconds, unless_exist: true)
      if ActiveModel::Type::Boolean.new.cast(written)
        return Reservation.new(
          reserved: true,
          token: token,
          reserved_at: now,
          lease_seconds: ttl,
          remaining_seconds: ttl
        )
      end

      existing = Rails.cache.read(key)
      Reservation.new(
        reserved: false,
        lease_seconds: ttl,
        remaining_seconds: remaining_seconds_from(payload: existing, now: now, default_ttl: ttl),
        blocked_by: existing.is_a?(Hash) ? existing["source"].to_s.presence : nil
      )
    rescue StandardError
      Reservation.new(
        reserved: true,
        token: nil,
        reserved_at: now,
        lease_seconds: lease_seconds.to_i,
        remaining_seconds: 0
      )
    end

    private

    def cache_key(account_id:)
      "autonomous_scheduler:lease:account:#{account_id.to_i}"
    end

    def remaining_seconds_from(payload:, now:, default_ttl:)
      return 0 unless payload.is_a?(Hash)

      reserved_at = Time.zone.parse(payload["reserved_at"].to_s) rescue nil
      return 0 if reserved_at.blank?

      ttl = payload["lease_seconds"].to_i
      ttl = default_ttl if ttl <= 0
      remaining = (reserved_at + ttl.seconds - now).ceil
      remaining.positive? ? remaining : 0
    rescue StandardError
      0
    end
  end
end
