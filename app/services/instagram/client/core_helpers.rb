module Instagram
  class Client
    # Generic low-level helpers shared across the facade. Methods that take
    # a `driver` or `el` accept either Selenium or Playwright objects and
    # dispatch internally (see Instagram::Browser::Config.playwright_driver?).
    module CoreHelpers
      private

      def parse_unix_time(value)
        return nil if value.blank?
        Time.at(value.to_i).utc
      rescue StandardError
        nil
      end

      def cookie_header_for(cookies)
        Array(cookies).map do |c|
          name = c["name"].to_s
          value = c["value"].to_s
          next if name.blank? || value.blank?
          "#{name}=#{value}"
        end.compact.join("; ")
      end

      # Element-level check. Works on a Selenium WebElement or a Playwright
      # Locator/ElementHandle. We duck-type on :get_attribute (Playwright)
      # vs :attribute (Selenium).
      def element_enabled?(el)
        return false unless el

        if el.respond_to?(:get_attribute)
          element_enabled_playwright?(el)
        else
          element_enabled_selenium?(el)
        end
      end

      def human_pause(min_seconds = 0.15, max_seconds = 0.55)
        return if max_seconds.to_f <= 0
        min = min_seconds.to_f
        max = max_seconds.to_f
        d = min + (rand * (max - min))
        sleep(d.clamp(0.0, 2.0))
      end

      def maybe_capture_filmstrip(driver, label:, seconds: 5.0, interval: 0.5)
        return unless ENV["INSTAGRAM_FILMSTRIP"].present?

        if Instagram::Browser::Config.playwright_driver?(driver)
          maybe_capture_filmstrip_playwright(driver, label: label, seconds: seconds, interval: interval)
        else
          maybe_capture_filmstrip_selenium(driver, label: label, seconds: seconds, interval: interval)
        end
      end

      def wait_for(driver, css: nil, xpath: nil, timeout: 10)
        if Instagram::Browser::Config.playwright_driver?(driver)
          wait_for_playwright(driver, css: css, xpath: xpath, timeout: timeout)
        else
          wait_for_selenium(driver, css: css, xpath: xpath, timeout: timeout)
        end
      end

      def wait_for_present(driver, css: nil, xpath: nil, timeout: 10)
        if Instagram::Browser::Config.playwright_driver?(driver)
          wait_for_present_playwright(driver, css: css, xpath: xpath, timeout: timeout)
        else
          wait_for_present_selenium(driver, css: css, xpath: xpath, timeout: timeout)
        end
      end

      def websocket_tls_guidance(verify)
        tls = verify[:tls_issue].to_h
        reason = tls[:reason].presence || "certificate validation error"
        "Instagram DM transport failed: #{reason}. "\
        "Chrome could not establish a trusted secure connection to Instagram chat endpoints. "\
        "Install/trust the system CA used by your network proxy or, for local debugging only, "\
        "set INSTAGRAM_CHROME_IGNORE_CERT_ERRORS=true and retry."
      end

      def detect_websocket_tls_issue(driver)
        if Instagram::Browser::Config.playwright_driver?(driver)
          detect_websocket_tls_issue_playwright(driver)
        else
          detect_websocket_tls_issue_selenium(driver)
        end
      end

      def normalize_username(value)
        value.to_s.strip.downcase.gsub(/[^a-z0-9._]/, "")
      end

      def normalize_count(value)
        text = value.to_s.strip
        return nil unless text.match?(/\A\d+\z/)

        text.to_i
      rescue StandardError
        nil
      end

      # --- Selenium implementations (legacy; removed in Phase 5) -----------

      def element_enabled_selenium?(el)
        return false unless (el.displayed? rescue true)

        disabled_attr = (el.attribute("disabled") rescue nil).to_s
        aria_disabled = (el.attribute("aria-disabled") rescue nil).to_s

        disabled_attr.blank? && aria_disabled != "true"
      rescue StandardError
        true
      end

      def maybe_capture_filmstrip_selenium(driver, label:, seconds:, interval:)
        root = DEBUG_CAPTURE_DIR.join(Time.current.utc.strftime("%Y%m%d"))
        FileUtils.mkdir_p(root)

        started = Time.current.utc
        deadline = started + seconds.to_f
        frames = []
        i = 0

        while Time.current.utc < deadline
          ts = Time.current.utc.strftime("%Y%m%dT%H%M%S.%LZ")
          safe = label.to_s.downcase.gsub(/[^a-z0-9]+/, "_").gsub(/\A_|_\z/, "")
          path = root.join("#{ts}_filmstrip_#{safe}_#{format('%03d', i)}.png")
          begin
            driver.save_screenshot(path.to_s)
            frames << path.to_s
          rescue StandardError
            # best effort
          end
          i += 1
          sleep(interval.to_f)
        end

        meta = {
          timestamp: Time.current.utc.iso8601(3),
          label: label,
          seconds: seconds,
          interval: interval,
          frames: frames
        }
        File.write(root.join("#{started.strftime('%Y%m%dT%H%M%S.%LZ')}_filmstrip_#{label}.json"), JSON.pretty_generate(meta))
      rescue StandardError
        nil
      end

      def wait_for_selenium(driver, css:, xpath:, timeout:)
        wait = Selenium::WebDriver::Wait.new(timeout: timeout)
        wait.until do
          if css
            elements = driver.find_elements(css: css)
            elements.each do |el|
              begin
                return el if el.displayed?
              rescue Selenium::WebDriver::Error::StaleElementReferenceError
                next
              end
            end
            nil
          elsif xpath
            elements = driver.find_elements(xpath: xpath)
            elements.each do |el|
              begin
                return el if el.displayed?
              rescue Selenium::WebDriver::Error::StaleElementReferenceError
                next
              end
            end
            nil
          end
        end
      end

      def wait_for_present_selenium(driver, css:, xpath:, timeout:)
        wait = Selenium::WebDriver::Wait.new(timeout: timeout)
        wait.until do
          if css
            driver.find_elements(css: css).any?
          elsif xpath
            driver.find_elements(xpath: xpath).any?
          end
        end
      end

      def detect_websocket_tls_issue_selenium(driver)
        return { found: false } unless driver.respond_to?(:logs)

        entries = driver.logs.get(:browser) rescue []
        messages = Array(entries).map { |e| e.message.to_s }

        # Common failure observed in this environment: the IG Direct gateway websocket fails TLS validation,
        # which can prevent DMs from actually being delivered even though the UI clears the composer.
        bad = messages.find { |m| m.include?("gateway.instagram.com/ws/streamcontroller") && m.include?("ERR_CERT_AUTHORITY_INVALID") }
        return { found: true, reason: "ERR_CERT_AUTHORITY_INVALID", message: bad.to_s.byteslice(0, 2000) } if bad

        other = messages.find { |m| m.include?("ERR_CERT_AUTHORITY_INVALID") }
        return { found: true, reason: "ERR_CERT_AUTHORITY_INVALID", message: other.to_s.byteslice(0, 2000) } if other

        { found: false }
      rescue StandardError => e
        { found: false, error: "#{e.class}: #{e.message}" }
      end

      # --- Playwright implementations (Phase 3 port) -----------------------

      def element_enabled_playwright?(el)
        # visible?/is_visible vary by object type. Locator responds to
        # .visible?, ElementHandle to .visible? too; both raise on detach.
        visible =
          if el.respond_to?(:visible?)
            (el.visible? rescue true)
          else
            true
          end
        return false unless visible

        disabled = (el.get_attribute("disabled") rescue nil).to_s
        aria = (el.get_attribute("aria-disabled") rescue nil).to_s
        disabled.blank? && aria != "true"
      rescue StandardError
        true
      end

      def maybe_capture_filmstrip_playwright(page, label:, seconds:, interval:)
        root = DEBUG_CAPTURE_DIR.join(Time.current.utc.strftime("%Y%m%d"))
        FileUtils.mkdir_p(root)

        started = Time.current.utc
        deadline = started + seconds.to_f
        frames = []
        i = 0

        while Time.current.utc < deadline
          ts = Time.current.utc.strftime("%Y%m%dT%H%M%S.%LZ")
          safe = label.to_s.downcase.gsub(/[^a-z0-9]+/, "_").gsub(/\A_|_\z/, "")
          path = root.join("#{ts}_filmstrip_#{safe}_#{format('%03d', i)}.png")
          begin
            page.screenshot(path: path.to_s)
            frames << path.to_s
          rescue StandardError
            # best effort
          end
          i += 1
          sleep(interval.to_f)
        end

        meta = {
          timestamp: Time.current.utc.iso8601(3),
          label: label,
          seconds: seconds,
          interval: interval,
          frames: frames
        }
        File.write(root.join("#{started.strftime('%Y%m%dT%H%M%S.%LZ')}_filmstrip_#{label}.json"), JSON.pretty_generate(meta))
      rescue StandardError
        nil
      end

      # Playwright waits return the locator / true on success and raise a
      # Playwright::TimeoutError on timeout. Timeout is in ms at the
      # Playwright layer; callers pass seconds so we multiply.
      def wait_for_playwright(page, css:, xpath:, timeout:)
        selector = css || (xpath && "xpath=#{xpath}")
        return nil unless selector

        locator = page.locator(selector).first
        locator.wait_for(state: "visible", timeout: (timeout.to_f * 1_000).to_i)
        locator
      end

      def wait_for_present_playwright(page, css:, xpath:, timeout:)
        selector = css || (xpath && "xpath=#{xpath}")
        return false unless selector

        locator = page.locator(selector).first
        locator.wait_for(state: "attached", timeout: (timeout.to_f * 1_000).to_i)
        true
      end

      # Playwright has no equivalent of Selenium's driver.logs.get(:browser).
      # TaskCaptureSupport (Phase 3 step 3) will wire up a per-context
      # page.on("console") accumulator we can introspect here. Until that
      # lands, the TLS-issue probe is a safe no-op on the Playwright path.
      def detect_websocket_tls_issue_playwright(_page)
        { found: false, reason: "tls_probe_unavailable_on_playwright" }
      rescue StandardError => e
        { found: false, error: "#{e.class}: #{e.message}" }
      end
    end
  end
end
