# frozen_string_literal: true

# Phase 2 (Playwright migration): exposes a single feature flag that Phase 3
# port commits will branch on. Intentionally does nothing today — Selenium
# remains the default and only driver actually driving the Instagram
# facade until per-module ports land.
#
# Valid values:
#   "selenium" (default) — legacy Instagram::Client::BrowserAutomation path
#   "playwright"         — Instagram::Browser::AccountContext path
#
# Override precedence: ENV -> Rails credentials (:instagram :browser_driver)
# -> default.

module Instagram
  module Browser
    module Config
      VALID_DRIVERS = %w[selenium playwright].freeze
      DEFAULT_DRIVER = "selenium".freeze

      class << self
        # "selenium" or "playwright"
        def driver
          value = (ENV["INSTAGRAM_BROWSER_DRIVER"].presence ||
                   Rails.application.credentials.dig(:instagram, :browser_driver).presence ||
                   DEFAULT_DRIVER).to_s.downcase

          VALID_DRIVERS.include?(value) ? value : DEFAULT_DRIVER
        end

        def playwright?
          driver == "playwright"
        end

        def selenium?
          driver == "selenium"
        end

        # True when `obj` looks like a Playwright object (Page, BrowserContext,
        # Locator, ElementHandle, ...). Used by Instagram::Client support
        # modules to dispatch between the legacy Selenium path and the
        # Phase 3 Playwright port without a global mode flag -- a single
        # module can be consuming both drivers during the rollout if a
        # caller hands it a mocked Selenium driver.
        def playwright_driver?(obj)
          klass = obj&.class&.name.to_s
          klass.start_with?("Playwright::") ||
            klass.include?("PlaywrightApi::")
        end

        def selenium_driver?(obj)
          klass = obj&.class&.name.to_s
          klass.start_with?("Selenium::")
        end
      end
    end
  end
end

Rails.application.config.after_initialize do
  Rails.logger&.info(
    "[instagram.browser] driver=#{Instagram::Browser::Config.driver} " \
    "(INSTAGRAM_BROWSER_DRIVER=#{ENV['INSTAGRAM_BROWSER_DRIVER'].inspect})"
  )
end
