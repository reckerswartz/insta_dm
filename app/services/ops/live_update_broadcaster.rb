module Ops
  class LiveUpdateBroadcaster
    THROTTLE_CACHE_PREFIX = "ops:live_update:throttle".freeze

    class << self
      def global_stream
        "operations:global"
      end

      def account_stream(account_id)
        "operations:account:#{account_id}"
      end

      def broadcast!(topic:, account_id: nil, payload: {}, throttle_key: nil, throttle_seconds: 0.8)
        return if throttled?(topic: topic, account_id: account_id, throttle_key: throttle_key, throttle_seconds: throttle_seconds)

        message = base_message(topic: topic, payload: payload)
        ActionCable.server.broadcast(global_stream, message)
        ActionCable.server.broadcast(account_stream(account_id), message) if account_id.to_i.positive?
      rescue StandardError => e
        Rails.logger.warn("[ops.live_update] broadcast failed: #{e.class}: #{e.message}")
      end

      private

      def base_message(topic:, payload:)
        {
          topic: topic.to_s,
          sent_at: Time.current.iso8601(3),
          payload: payload.is_a?(Hash) ? payload : {}
        }
      end

      def throttled?(topic:, account_id:, throttle_key:, throttle_seconds:)
        ttl = throttle_seconds.to_f
        return false if ttl <= 0

        key = cache_key(topic: topic, account_id: account_id, throttle_key: throttle_key)
        already_written = Rails.cache.read(key)
        return true if already_written

        Rails.cache.write(key, true, expires_in: ttl.seconds)
        false
      rescue StandardError
        false
      end

      def cache_key(topic:, account_id:, throttle_key:)
        suffix = throttle_key.presence || topic.to_s
        "#{THROTTLE_CACHE_PREFIX}:#{account_id.to_i}:#{suffix}"
      end
    end
  end
end
