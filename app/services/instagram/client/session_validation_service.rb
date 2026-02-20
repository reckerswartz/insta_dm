module Instagram
  class Client
    class SessionValidationService
      AUTHENTICATED_SELECTORS = [
        "svg[aria-label='Home']",
        "svg[aria-label='Search']",
        "img[alt*='profile picture']",
        "a[href*='/direct/inbox/']",
        "[aria-label='Settings']",
        ".x9f619",
        ".x78zum5",
        ".x1i10hfl"
      ].freeze

      PROFILE_INDICATORS = [
        "img[alt*='profile picture']",
        "h2",
        "a[href*='/followers/']",
        "a[href*='/following/']"
      ].freeze

      MIN_REQUIRED_INDICATORS = 3

      def initialize(account:, with_driver:, wait_for:, logger: nil, base_url: Client::INSTAGRAM_BASE_URL)
        @account = account
        @with_driver = with_driver
        @wait_for = wait_for
        @logger = logger
        @base_url = base_url
      end

      def call
        return { valid: false, message: "No cookies stored" } if account.cookies.empty?

        with_driver.call(headless: true) do |driver|
          driver.navigate.to(base_url)
          wait_for.call(driver, css: "body", timeout: 12)

          if login_redirect?(driver.current_url)
            return { valid: false, message: "Session expired - redirected to login page" }
          end

          begin
            authenticated_found, found_selectors = count_visible_indicators(driver, AUTHENTICATED_SELECTORS)
            if authenticated_found >= MIN_REQUIRED_INDICATORS
              return validate_profile_access(driver: driver, authenticated_found: authenticated_found, found_selectors: found_selectors)
            end

            {
              valid: false,
              message: "Session appears to be invalid - only found #{authenticated_found}/#{AUTHENTICATED_SELECTORS.length} authentication indicators",
              details: {
                homepage_indicators: authenticated_found,
                required_indicators: MIN_REQUIRED_INDICATORS,
                found_selectors: found_selectors
              }
            }
          rescue StandardError => e
            { valid: false, message: "Session validation error: #{e.message}" }
          end
        end
      rescue StandardError => e
        { valid: false, message: "Validation failed: #{e.message}" }
      end

      private

      attr_reader :account, :with_driver, :wait_for, :logger, :base_url

      def validate_profile_access(driver:, authenticated_found:, found_selectors:)
        driver.navigate.to("#{base_url}/#{account.username}/")
        wait_for.call(driver, css: "body", timeout: 8)

        if login_redirect?(driver.current_url)
          return { valid: false, message: "Session invalid - cannot access profile page" }
        end

        profile_elements_found = PROFILE_INDICATORS.sum do |selector|
          begin
            visible_element_count(driver: driver, selector: selector).positive? ? 1 : 0
          rescue StandardError
            0
          end
        end

        {
          valid: true,
          message: "Session is valid and authenticated (found #{authenticated_found}/#{AUTHENTICATED_SELECTORS.length} indicators, #{profile_elements_found} profile elements)",
          details: {
            homepage_indicators: authenticated_found,
            profile_indicators: profile_elements_found,
            found_selectors: found_selectors
          }
        }
      end

      def count_visible_indicators(driver, selectors)
        found_selectors = []
        count = 0

        selectors.each do |selector|
          begin
            visible_count = visible_element_count(driver: driver, selector: selector)
            next unless visible_count.positive?

            count += 1
            found_selectors << "#{selector} (#{visible_count})"
          rescue StandardError => e
            if ignorable_selector_error?(e)
              next
            end

            logger&.warn("Validation selector error for #{selector}: #{e.message}")
          end
        end

        [count, found_selectors]
      end

      def visible_element_count(driver:, selector:)
        elements = driver.find_elements(css: selector)
        elements.select(&:displayed?).length
      end

      def ignorable_selector_error?(error)
        error.is_a?(Selenium::WebDriver::Error::NoSuchElementError) ||
          error.is_a?(Selenium::WebDriver::Error::StaleElementReferenceError)
      rescue NameError
        false
      end

      def login_redirect?(url)
        value = url.to_s
        value.include?("/accounts/login/") || value.include?("/accounts/emailsignup/")
      end
    end
  end
end
