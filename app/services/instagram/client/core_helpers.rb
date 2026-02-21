module Instagram
  class Client
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

      def element_enabled?(el)
        return false unless el
        return false unless (el.displayed? rescue true)

        disabled_attr = (el.attribute("disabled") rescue nil).to_s
        aria_disabled = (el.attribute("aria-disabled") rescue nil).to_s

        disabled_attr.blank? && aria_disabled != "true"
      rescue StandardError
        true
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

      def wait_for(driver, css: nil, xpath: nil, timeout: 10)
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

      def wait_for_present(driver, css: nil, xpath: nil, timeout: 10)
        wait = Selenium::WebDriver::Wait.new(timeout: timeout)
        wait.until do
          if css
            driver.find_elements(css: css).any?
          elsif xpath
            driver.find_elements(xpath: xpath).any?
          end
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

    end
  end
end
