class FeedCaptureThrottle
  Reservation = Struct.new(
    :reserved,
    :reserved_at,
    :previous_enqueued_at,
    :remaining_seconds,
    keyword_init: true
  )

  MIN_INTERVAL_SECONDS = ENV.fetch("FEED_CAPTURE_MIN_INTERVAL_SECONDS", "300").to_i.clamp(30, 3600)

  class << self
    def min_interval_seconds
      MIN_INTERVAL_SECONDS
    end

    def remaining_seconds(account:, now: Time.current)
      last_enqueued_at = account&.continuous_processing_last_feed_sync_enqueued_at
      return 0 if last_enqueued_at.blank?

      remaining = min_interval_seconds - (now.to_f - last_enqueued_at.to_f)
      remaining.positive? ? remaining.ceil : 0
    rescue StandardError
      0
    end

    def locked?(account:, now: Time.current)
      remaining_seconds(account: account, now: now).positive?
    end

    def reserve!(account:, now: Time.current)
      return Reservation.new(reserved: false, remaining_seconds: 0) if account.blank?

      reserved = false
      previous_enqueued_at = nil
      remaining = 0
      reserved_at = nil

      account.with_lock do
        previous_enqueued_at = account.continuous_processing_last_feed_sync_enqueued_at
        remaining = remaining_from(last_enqueued_at: previous_enqueued_at, now: now)
        next if remaining.positive?

        reserved_at = now
        account.update_columns(
          continuous_processing_last_feed_sync_enqueued_at: reserved_at,
          updated_at: Time.current
        )
        reserved = true
      end

      Reservation.new(
        reserved: reserved,
        reserved_at: reserved_at,
        previous_enqueued_at: previous_enqueued_at,
        remaining_seconds: remaining
      )
    rescue StandardError
      Reservation.new(reserved: false, remaining_seconds: 0)
    end

    def release!(account:, previous_enqueued_at:)
      return false if account.blank?

      account.update_columns(
        continuous_processing_last_feed_sync_enqueued_at: previous_enqueued_at,
        updated_at: Time.current
      )
      true
    rescue StandardError
      false
    end

    private

    def remaining_from(last_enqueued_at:, now:)
      return 0 if last_enqueued_at.blank?

      remaining = min_interval_seconds - (now.to_f - last_enqueued_at.to_f)
      remaining.positive? ? remaining.ceil : 0
    end
  end
end
