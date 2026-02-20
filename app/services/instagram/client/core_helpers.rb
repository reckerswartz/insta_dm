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

      def extract_profile_follow_counts(html)
        # Best-effort; depends on English locale. Example:
        # "246 Followers, 661 Following, 37 Posts - See Instagram photos..."
        m = html.to_s.match(/content=\"\s*([\d,]+)\s*Followers,\s*([\d,]+)\s*Following\b/i)
        return nil unless m

        {
          followers: m[1].to_s.delete(",").to_i,
          following: m[2].to_s.delete(",").to_i
        }
      rescue StandardError
        nil
      end

      def extract_story_users_from_home_html(html)
        return [] if html.blank?

        # Try multiple preloader patterns with more aggressive matching
        patterns = [
          "adp_PolarisStoriesV3TrayContainerQueryRelayPreloader_",
          "adp_PolarisStoriesV",
          "StoriesTrayContainer", 
          "stories_tray",
          "story-tray",
          "StoryTray",
          "storyTray",
          "stories-container",
          "storiesContainer"
        ]
      
        idx = nil
        window = ""
      
        patterns.each do |pattern|
          idx = html.index(pattern)
          if idx
            window = html.byteslice(idx, 800_000) || ""
            break
          end
        end
      
        # If no preloader found, try direct username extraction from the entire HTML
        if idx.nil?
          # Look for any story-related patterns in the HTML
          story_patterns = [
            /\"username\":\"([A-Za-z0-9._]{1,30})\"[\s\S]{0,1000}\"has_story\":true/,
            /\"user\":\{[\s\S]{0,2000}\"username\":\"([A-Za-z0-9._]{1,30})\"[\s\S]{0,2000}\"has_?story\":\s*true/,
            /\"([A-Za-z0-9._]{1,30})\"[\s\S]{0,500}\"story\"/,
            /\/stories\/([A-Za-z0-9._]{1,30})\//
          ]
        
          usernames = []
          story_patterns.each do |pattern|
            matches = html.scan(pattern)
            if matches.is_a?(Array)
              matches = matches.flatten if matches.first.is_a?(Array)
              usernames.concat(matches)
            end
          end
        
          return usernames.map { |u| normalize_username(u) }.reject(&:blank?).uniq.take(12)
        end

        # Prefer story-tray item extraction
        tray_usernames = window.scan(/\"user\":\{[\s\S]{0,4000}?\"username\":\"([A-Za-z0-9._]{1,30})\"[\s\S]{0,4000}?\"uuid\":\"/).flatten
        tray_usernames = tray_usernames.map { |u| normalize_username(u) }.reject(&:blank?).uniq
        return tray_usernames unless tray_usernames.empty?

        # Fallback: grab usernames in this payload window
        usernames = window.scan(/\"username\":\"([A-Za-z0-9._]{1,30})\"/).flatten.map { |u| normalize_username(u) }
        usernames.reject(&:blank?).uniq
      rescue StandardError => e
        Rails.logger.error "Story extraction error: #{e.message}" if defined?(Rails)
        []
      end
    end
  end
end
