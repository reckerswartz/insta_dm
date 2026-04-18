module Instagram
  class Client
    # Facade entry point into browser automation. Dispatches to either the
    # legacy Selenium path or the Phase 3 Playwright path based on
    # Instagram::Browser::Config.playwright?.
    #
    # Playwright mode:
    #   * Uses Instagram::Browser::AccountContext -> one persistent context
    #     per InstagramAccount on disk at storage/browser_sessions/<id>/.
    #   * The yielded "driver" is a Playwright::Page (with PageInstrumentation
    #     attached by AccountContext#with_page) rather than a Selenium driver.
    #   * apply_session_bundle! / persist_session_bundle! go through
    #     Instagram::Browser::SessionExporter for DB <-> storage_state sync.
    #   * manual_login! opens a non-headless page and polls for the
    #     sessionid cookie just like before.
    #
    # Selenium mode (unchanged): Selenium::WebDriver.for(:chrome, ...).
    module BrowserAutomation
      def with_authenticated_driver(&block)
        if Instagram::Browser::Config.playwright?
          with_authenticated_driver_playwright(&block)
        else
          with_authenticated_driver_selenium(&block)
        end
      end

      def with_driver(headless: env_headless?, &block)
        if Instagram::Browser::Config.playwright?
          with_driver_playwright(headless: headless, &block)
        else
          with_driver_selenium(headless: headless, &block)
        end
      end

      def env_headless?
        Rails.application.config.x.instagram.headless == true
      end

      # --- Selenium implementations (legacy; removed in Phase 5) -----------

      def with_authenticated_driver_selenium
        if @account.cookies.blank?
          raise AuthenticationRequiredError, "No stored cookies. Use manual login or import cookies first."
        end

        with_driver_selenium do |driver|
          apply_session_bundle_selenium!(driver)
          driver.navigate.to("#{INSTAGRAM_BASE_URL}/")
          ensure_authenticated_selenium!(driver)

          result = yield(driver)
          refresh_account_snapshot_selenium!(driver)
          result
        end
      end

      def with_driver_selenium(headless: env_headless?)
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

      def wait_for_manual_login_selenium!(driver:, timeout_seconds:)
        timeout_at = Time.now + timeout_seconds

        loop do
          cookie_names = driver.manage.all_cookies.map { |c| c[:name] }
          return if cookie_names.include?("sessionid")

          raise "Timed out waiting for manual Instagram login" if Time.now > timeout_at

          sleep(1)
        end
      end

      def persist_cookies_selenium!(driver)
        @account.cookies = driver.manage.all_cookies.map { |cookie| cookie.transform_keys(&:to_s) }
      end

      def persist_session_bundle_selenium!(driver)
        # Capture after successful 2FA and redirect to authenticated session.
        @account.user_agent = safe_driver_value(driver) { driver.execute_script("return navigator.userAgent") }

        persist_cookies_selenium!(driver)
        @account.local_storage = read_web_storage(driver, "localStorage")
        @account.session_storage = read_web_storage(driver, "sessionStorage")
        ig_app_id = detect_ig_app_id_selenium(driver)

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

      def refresh_account_snapshot_selenium!(driver)
        persist_session_bundle_selenium!(driver)
        @account.save! if @account.changed?
      rescue StandardError => e
        Rails.logger.warn("Instagram snapshot refresh skipped: #{e.class}: #{e.message}")
      end

      def apply_session_bundle_selenium!(driver)
        # Need a base navigation first so Chrome is on the correct domain for cookies + storage.
        driver.navigate.to(INSTAGRAM_BASE_URL)

        apply_cookies_selenium!(driver)
        write_web_storage(driver, "localStorage", @account.local_storage)
        write_web_storage(driver, "sessionStorage", @account.session_storage)
      end

      def detect_ig_app_id_selenium(driver)
        detected = safe_driver_value(driver) { driver.execute_script(ig_app_id_probe_script) }.to_s.strip
        return detected if detected.present?

        @account.auth_snapshot.dig("ig_app_id").to_s.presence || "936619743392459"
      rescue StandardError
        @account.auth_snapshot.dig("ig_app_id").to_s.presence || "936619743392459"
      end

      def apply_cookies_selenium!(driver)
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

      def ensure_authenticated_selenium!(driver)
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

      # --- Playwright implementations (Phase 3 port) -----------------------

      def with_driver_playwright(headless: env_headless?, &block)
        account_context = Instagram::Browser::AccountContext.new(account: @account, headless: headless)
        account_context.with_context do |context|
          page = context.pages.first || context.new_page
          Instagram::Browser::PageInstrumentation.attach!(page)
          shim = Instagram::Browser::SeleniumApiShim.new(page: page, context: context)
          block.call(shim)
        end
      end

      def with_authenticated_driver_playwright
        has_on_disk_profile = Instagram::Browser::AccountContext.new(account: @account).exists_on_disk?
        if !has_on_disk_profile && @account.cookies.blank?
          raise Instagram::AuthenticationRequiredError, "No stored cookies and no persistent browser profile. Use manual login or import cookies first."
        end

        Instagram::Browser::AccountContext.new(account: @account).with_context do |context|
          page = context.pages.first || context.new_page
          Instagram::Browser::PageInstrumentation.attach!(page)
          shim = Instagram::Browser::SeleniumApiShim.new(page: page, context: context)

          # If the on-disk profile is empty but the DB has cookies, seed
          # the context from the DB bundle so the first Playwright-mode
          # run works without a manual_login!.
          apply_session_bundle_playwright!(context) if !has_on_disk_profile && @account.cookies.present?

          page.goto("#{INSTAGRAM_BASE_URL}/")
          ensure_authenticated_playwright!(shim)

          result = yield(shim)
          refresh_account_snapshot_playwright!(page, context)
          result
        end
      end

      def apply_session_bundle_playwright!(context)
        state = Instagram::Browser::SessionExporter.new(account: @account).storage_state
        cookies = state[:cookies].to_a
        context.add_cookies(cookies) if cookies.any?

        # localStorage can only be written once the page is on the origin.
        # Navigate to each origin and replay its entries via page.evaluate.
        state[:origins].each do |origin_entry|
          origin = origin_entry[:origin].to_s
          entries = origin_entry[:localStorage].to_a
          next if origin.blank? || entries.empty?

          page = context.pages.first || context.new_page
          page.goto(origin)
          write_web_storage_playwright(page, "localStorage", entries.map { |e| { key: e[:name], value: e[:value] } })
        end
      rescue StandardError => e
        Rails.logger.warn("Instagram apply_session_bundle_playwright skipped: #{e.class}: #{e.message}")
      end

      def wait_for_manual_login_playwright!(context:, timeout_seconds:)
        timeout_at = Time.now + timeout_seconds

        loop do
          cookie_names = context.cookies.map { |c| (c[:name] || c["name"]).to_s }
          return if cookie_names.include?("sessionid")

          raise "Timed out waiting for manual Instagram login" if Time.now > timeout_at

          sleep(1)
        end
      end

      def persist_session_bundle_playwright!(page, context)
        exporter = Instagram::Browser::SessionExporter.new(account: @account)
        exporter.export!(context)

        # Extra metadata beyond what SessionExporter writes: page-derived
        # user agent + ig_app_id probe + auth_snapshot timestamps.
        @account.user_agent =
          safe_driver_value(page) { page.evaluate("() => navigator.userAgent") } || @account.user_agent
        ig_app_id = detect_ig_app_id_playwright(page)

        snapshot = (@account.auth_snapshot || {}).merge(
          "captured_at" => Time.current.utc.iso8601(3),
          "current_url" => safe_driver_value(page) { page.url },
          "page_title" => safe_driver_value(page) { page.title },
          "ig_app_id" => ig_app_id,
          "sessionid_present" => @account.cookies.any? { |c| c["name"].to_s == "sessionid" && c["value"].to_s.present? },
          "cookie_names" => @account.cookies.map { |c| c["name"] }.compact.uniq.sort,
          "local_storage_keys" => @account.local_storage.map { |e| e["key"] || e[:key] }.compact.uniq.sort
        )
        @account.auth_snapshot = snapshot
      end

      def refresh_account_snapshot_playwright!(page, context)
        persist_session_bundle_playwright!(page, context)
        @account.save! if @account.changed?
      rescue StandardError => e
        Rails.logger.warn("Instagram snapshot refresh skipped: #{e.class}: #{e.message}")
      end

      def detect_ig_app_id_playwright(page)
        detected = safe_driver_value(page) { page.evaluate(ig_app_id_probe_script) }.to_s.strip
        return detected if detected.present?

        @account.auth_snapshot.dig("ig_app_id").to_s.presence || "936619743392459"
      rescue StandardError
        @account.auth_snapshot.dig("ig_app_id").to_s.presence || "936619743392459"
      end

      def ensure_authenticated_playwright!(driver)
        # `driver` is an Instagram::Browser::SeleniumApiShim wrapping the
        # real Playwright page. Calls below use the Selenium-shaped
        # interface the shim exposes; they forward to Playwright.
        with_task_capture(driver: driver, task_name: "auth_validate_session") do
          wait_for(driver, css: "body", timeout: 10)

          driver.navigate.to("#{INSTAGRAM_BASE_URL}/direct/inbox/")
          wait_for(driver, css: "body", timeout: 10)

          if driver.current_url.to_s.include?("/accounts/login") || logged_out_page?(driver)
            raise Instagram::AuthenticationRequiredError, "Stored cookies are not authenticated. Re-run Manual Browser Login or import fresh cookies."
          end
        end
      end

      # --- Shared probes (used by both paths via dispatch above) ----------

      def ig_app_id_probe_script
        <<~JS
          () => {
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
          }
        JS
      end
    end
  end
end
