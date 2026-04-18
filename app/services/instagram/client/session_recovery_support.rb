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
        # Class-level checks for the known-good signatures on each driver.
        # `defined?` guards are kept so the recovery helper stays loadable
        # even after selenium-webdriver is removed in Phase 5.
        if defined?(Selenium::WebDriver::Error::InvalidSessionIdError) &&
           error.is_a?(Selenium::WebDriver::Error::InvalidSessionIdError)
          return true
        end

        # Playwright raises Playwright::Error (a StandardError subclass) with
        # descriptive messages we fall through to below -- no class check
        # is strictly necessary, but we keep one defensively for future gem
        # revisions that might add specific classes.
        if defined?(Playwright::Error) && error.is_a?(Playwright::Error)
          return true if error.message.to_s.match?(/target (page, context or browser )?(has been )?closed|browser has been closed|connection closed/i)
        end

        message = error.message.to_s.downcase
        # Selenium-shaped messages (retained)
        return true if message.include?("not connected to devtools")
        return true if message.include?("session deleted as the browser has closed the connection")
        return true if message.include?("disconnected")

        # Playwright-shaped messages
        return true if message.include?("target closed")
        return true if message.include?("target page, context or browser has been closed")
        return true if message.include?("browser has been closed")
        return true if message.include?("connection closed")

        false
      end
    end
  end
end
