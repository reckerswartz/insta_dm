require "json"

module Ops
  class StructuredLogger
    class << self
      def info(event:, payload: {})
        write(level: :info, event: event, payload: payload)
      end

      def warn(event:, payload: {})
        write(level: :warn, event: event, payload: payload)
      end

      def error(event:, payload: {})
        write(level: :error, event: event, payload: payload)
      end

      def write(level:, event:, payload: {})
        logger = Rails.logger
        method = logger.respond_to?(level) ? level : :info
        logger.public_send(method, serialize(event: event, payload: payload))
      rescue StandardError
        nil
      end

      private

      def serialize(event:, payload: {})
        data = {
          ts: Time.current.iso8601(3),
          event: event.to_s,
          pid: Process.pid
        }

        payload_hash = payload.is_a?(Hash) ? payload : { message: payload.to_s }
        data.merge!(payload_hash.compact)
        JSON.generate(data)
      end
    end
  end
end
