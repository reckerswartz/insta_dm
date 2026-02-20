module Instagram
  class Client
    module BrowserAutomation
      def with_authenticated_driver
        if @account.cookies.blank?
          raise AuthenticationRequiredError, "No stored cookies. Use manual login or import cookies first."
        end

        with_driver do |driver|
          apply_session_bundle!(driver)
          driver.navigate.to("#{INSTAGRAM_BASE_URL}/")
          ensure_authenticated!(driver)

          result = yield(driver)
          refresh_account_snapshot!(driver)
          result
        end
      end

      def with_driver(headless: env_headless?)
        driver = Selenium::WebDriver.for(:chrome, options: chrome_options(headless: headless))
        yield(driver)
      ensure
        driver&.quit
      end

      def chrome_options(headless:)
        options = Selenium::WebDriver::Chrome::Options.new
        options.add_argument("--window-size=1400,1200")
        options.add_argument("--disable-notifications")
        options.add_argument("--disable-dev-shm-usage")
        options.add_argument("--disable-gpu")
        options.add_argument("--remote-debugging-pipe")
        options.add_argument("--no-sandbox")
        options.add_argument("--headless=new") if headless

        # Enable browser console + performance logs for debugging (captured into our task artifacts when available).
        # Note: ChromeDriver support varies by version; we guard reads in `capture_task_html`.
        options.add_option("goog:loggingPrefs", { browser: "ALL", performance: "ALL" })

        # Allow an opt-in bypass for corp TLS interception setups where the Selenium Chrome instance does not
        # trust the proxy CA. Keep this OFF by default.
        if ActiveModel::Type::Boolean.new.cast(ENV["INSTAGRAM_CHROME_IGNORE_CERT_ERRORS"])
          options.add_argument("--ignore-certificate-errors")
          options.add_argument("--ignore-ssl-errors=yes")
        end

        # Sticky sessions in headless are more reliable when we keep a consistent UA.
        if @account.user_agent.present?
          options.add_argument("--user-agent=#{@account.user_agent}")
        end

        options
      end

      def env_headless?
        Rails.application.config.x.instagram.headless == true
      end

      def wait_for_manual_login!(driver:, timeout_seconds:)
        timeout_at = Time.now + timeout_seconds

        loop do
          cookie_names = driver.manage.all_cookies.map { |c| c[:name] }
          return if cookie_names.include?("sessionid")

          raise "Timed out waiting for manual Instagram login" if Time.now > timeout_at

          sleep(1)
        end
      end

      def persist_cookies!(driver)
        @account.cookies = driver.manage.all_cookies.map { |cookie| cookie.transform_keys(&:to_s) }
      end

      def persist_session_bundle!(driver)
        # Capture after successful 2FA and redirect to authenticated session.
        @account.user_agent = safe_driver_value(driver) { driver.execute_script("return navigator.userAgent") }

        persist_cookies!(driver)
        @account.local_storage = read_web_storage(driver, "localStorage")
        @account.session_storage = read_web_storage(driver, "sessionStorage")
        ig_app_id = detect_ig_app_id(driver)

        @account.auth_snapshot = {
          captured_at: Time.current.utc.iso8601(3),
          current_url: safe_driver_value(driver) { driver.current_url },
          page_title: safe_driver_value(driver) { driver.title },
          ig_app_id: ig_app_id,
          sessionid_present: @account.cookies.any? { |c| c["name"].to_s == "sessionid" && c["value"].to_s.present? },
          cookie_names: @account.cookies.map { |c| c["name"] }.compact.uniq.sort,
          local_storage_keys: @account.local_storage.map { |e| e["key"] }.compact.uniq.sort,
          session_storage_keys: @account.session_storage.map { |e| e["key"] }.compact.uniq.sort
        }
      end

      def refresh_account_snapshot!(driver)
        persist_session_bundle!(driver)
        @account.save! if @account.changed?
      rescue StandardError => e
        Rails.logger.warn("Instagram snapshot refresh skipped: #{e.class}: #{e.message}")
      end

      def apply_session_bundle!(driver)
        # Need a base navigation first so Chrome is on the correct domain for cookies + storage.
        driver.navigate.to(INSTAGRAM_BASE_URL)

        apply_cookies!(driver)
        write_web_storage(driver, "localStorage", @account.local_storage)
        write_web_storage(driver, "sessionStorage", @account.session_storage)
      end

      def detect_ig_app_id(driver)
        script = <<~JS
          const candidates = []
          const push = (value) => {
            if (value === null || typeof value === "undefined") return
            const text = String(value)
            const match = text.match(/\\d{8,}/)
            if (match) candidates.push(match[0])
          }

          try { push(document.documentElement?.getAttribute("data-app-id")) } catch (e) {}
          try { push(window._sharedData?.config?.app_id) } catch (e) {}
          try { push(window.__initialData?.config?.app_id) } catch (e) {}
          try { push(window.localStorage?.getItem("ig_app_id")) } catch (e) {}
          try { push(window.localStorage?.getItem("app_id")) } catch (e) {}
          try { push(window.sessionStorage?.getItem("ig_app_id")) } catch (e) {}

          return candidates[0] || null
        JS

        detected = safe_driver_value(driver) { driver.execute_script(script) }.to_s.strip
        return detected if detected.present?

        @account.auth_snapshot.dig("ig_app_id").to_s.presence || "936619743392459"
      rescue StandardError
        @account.auth_snapshot.dig("ig_app_id").to_s.presence || "936619743392459"
      end

      def apply_cookies!(driver)
        driver.navigate.to(INSTAGRAM_BASE_URL)

        @account.cookies.each do |cookie|
          next if cookie["name"].blank? || cookie["value"].blank?

          sanitized_cookie = {
            name: cookie["name"],
            value: cookie["value"],
            path: cookie["path"] || "/",
            secure: bool(cookie["secure"]),
            http_only: bool(cookie["httpOnly"])
          }

          sanitized_cookie[:domain] = cookie["domain"] if cookie["domain"].present?
          sanitized_cookie[:same_site] = normalize_same_site(cookie["sameSite"])

          if cookie["expiry"].present?
            sanitized_cookie[:expires] = cookie["expiry"].to_i
          elsif cookie["expires"].present?
            sanitized_cookie[:expires] = cookie["expires"].to_i
          end

          driver.manage.add_cookie(sanitized_cookie)
        rescue Selenium::WebDriver::Error::UnableToSetCookieError
          # Retry without domain/same_site for host-only or incompatible cookie attributes.
          fallback_cookie = sanitized_cookie.except(:domain, :same_site)
          driver.manage.add_cookie(fallback_cookie)
        rescue Selenium::WebDriver::Error::InvalidCookieDomainError
          next
        rescue Selenium::WebDriver::Error::UnableToSetCookieError
          next
        end
      end

      def ensure_authenticated!(driver)
        with_task_capture(driver: driver, task_name: "auth_validate_session") do
          wait_for(driver, css: "body", timeout: 10)

          # Validate against inbox route because "/" can be public and still unauthenticated.
          driver.navigate.to("#{INSTAGRAM_BASE_URL}/direct/inbox/")
          wait_for(driver, css: "body", timeout: 10)

          if driver.current_url.include?("/accounts/login") || logged_out_page?(driver)
            raise AuthenticationRequiredError, "Stored cookies are not authenticated. Re-run Manual Browser Login or import fresh cookies."
          end
        end
      end

    end
  end
end
