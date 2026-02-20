module Instagram
  class Client
    module SessionRecoverySupport
      private

      def with_recoverable_session(label:, max_attempts: 2)
        attempt = 0

        begin
          attempt += 1
          yield
        rescue StandardError => e
          raise unless disconnected_session_error?(e)
          raise if attempt >= max_attempts

          Rails.logger.warn("Instagram #{label} recovered from browser disconnect (attempt #{attempt}/#{max_attempts}).")
          sleep(1)
          retry
        end
      end

      def disconnected_session_error?(error)
        return true if error.is_a?(Selenium::WebDriver::Error::InvalidSessionIdError)

        message = error.message.to_s.downcase
        message.include?("not connected to devtools") ||
          message.include?("session deleted as the browser has closed the connection") ||
          message.include?("disconnected")
      end
    end
  end
end
