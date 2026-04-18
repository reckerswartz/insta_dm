module Instagram
  class Client
    # Writes HTML + screenshot + JSON metadata artifacts for every Instagram
    # operation we want diagnosable. Works with either a Selenium driver
    # or a Playwright page; console + performance logs are only captured
    # on the Playwright path when Instagram::Browser::PageInstrumentation
    # has been attached to the page (done by AccountContext at launch).
    module TaskCaptureSupport
      private

      def with_task_capture(driver:, task_name:, meta: {})
        result = yield
        capture_task_html(driver: driver, task_name: task_name, status: "ok", meta: meta)
        result
      rescue StandardError => e
        capture_task_html(
          driver: driver,
          task_name: task_name,
          status: "error",
          meta: meta.merge(
            error_class: e.class.name,
            error_message: e.message,
            error_backtrace: Array(e.backtrace).take(40)
          )
        )
        raise
      end

      def capture_task_html(driver:, task_name:, status:, meta: {})
        timestamp = Time.current.utc.strftime("%Y%m%dT%H%M%S.%LZ")
        slug = task_name.to_s.downcase.gsub(/[^a-z0-9]+/, "_").gsub(/\A_|_\z/, "")
        root = DEBUG_CAPTURE_DIR.join(Time.current.utc.strftime("%Y%m%d"))
        FileUtils.mkdir_p(root)

        base = "#{timestamp}_#{slug}_#{status}"
        html_path = root.join("#{base}.html")
        json_path = root.join("#{base}.json")
        png_path = root.join("#{base}.png")

        playwright = Instagram::Browser::Config.playwright_driver?(driver)

        html = begin
          playwright ? driver.content.to_s : driver.page_source.to_s
        rescue StandardError => e
          "<!-- unable to capture page_source: #{e.class}: #{e.message} -->"
        end

        metadata = {
          timestamp: Time.current.utc.iso8601(3),
          task_name: task_name,
          status: status,
          account_username: @account.username,
          current_url: safe_driver_value(driver) { playwright ? driver.url : driver.current_url },
          page_title: safe_driver_value(driver) { driver.title }
        }.merge(meta)

        logs =
          if playwright
            capture_playwright_browser_logs(driver)
          else
            capture_selenium_browser_logs(driver)
          end
        metadata[:browser_console] = logs if logs.present?

        perf =
          if playwright
            capture_playwright_performance_logs(driver)
          else
            capture_selenium_performance_logs(driver)
          end
        if perf.present?
          metadata[:performance_summary] = summarize_performance_logs(perf)
          metadata[:performance_logs] = filter_performance_logs(perf)
        end

        # Screenshot helps catch transient toasts/overlays that aren't obvious from HTML.
        safe_driver_value(driver) do
          if playwright
            driver.screenshot(path: png_path.to_s)
          else
            driver.save_screenshot(png_path.to_s)
          end
          true
        end
        metadata[:screenshot] = png_path.to_s if File.exist?(png_path)

        File.write(html_path, html)
        File.write(json_path, JSON.pretty_generate(metadata))
      rescue StandardError => e
        Rails.logger.warn("Failed to write debug capture for #{task_name}: #{e.class}: #{e.message}")
      end

      def summarize_performance_logs(entries)
        # Chrome "performance" log entries are JSON strings.
        # We keep a small summary so the JSON artifacts stay readable.
        requests = []
        responses = {}

        Array(entries).each do |e|
          raw = e.is_a?(Hash) ? e[:message] || e["message"] : nil
          next if raw.blank?

          msg = JSON.parse(raw) rescue nil
          inner = msg.is_a?(Hash) ? msg["message"] : nil
          next unless inner.is_a?(Hash)

          method = inner["method"].to_s
          params = inner["params"].is_a?(Hash) ? inner["params"] : {}

          case method
          when "Network.requestWillBeSent"
            req = params["request"].is_a?(Hash) ? params["request"] : {}
            url = req["url"].to_s
            next if url.blank?
            next unless interesting_perf_url?(url)
            requests << { request_id: params["requestId"], url: url, http_method: req["method"] }
          when "Network.responseReceived"
            resp = params["response"].is_a?(Hash) ? params["response"] : {}
            url = resp["url"].to_s
            next if url.blank?
            next unless interesting_perf_url?(url)
            responses[params["requestId"].to_s] = { url: url, status: resp["status"], mime_type: resp["mimeType"] }
          end
        end

        recent = requests.last(40).map do |r|
          rid = r[:request_id].to_s
          r.merge(response: responses[rid])
        end

        {
          interesting_request_count: requests.size,
          recent_interesting: recent
        }
      rescue StandardError => e
        { error: "#{e.class}: #{e.message}" }
      end

      def filter_performance_logs(entries)
        # Keep only likely-relevant messages to avoid huge JSON artifacts.
        Array(entries).select do |e|
          raw = e.is_a?(Hash) ? e[:message] || e["message"] : nil
          next false if raw.blank?
          raw.include?("Network.requestWillBeSent") ||
            raw.include?("Network.responseReceived") ||
            raw.include?("Network.loadingFailed")
        end.last(200)
      end

      def interesting_perf_url?(url)
        u = url.to_s
        u.include?("/api/v1/") ||
          u.include?("/ajax/") ||
          u.include?("/graphql") ||
          u.include?("/direct") ||
          u.include?("direct_v2") ||
          u.include?("broadcast")
      end

      def safe_driver_value(driver)
        yield
      rescue StandardError
        nil
      end

      # --- Selenium log extractors (legacy) --------------------------------

      def capture_selenium_browser_logs(driver)
        safe_driver_value(driver) do
          next nil unless driver.respond_to?(:logs)
          types = driver.logs.available_types
          next nil unless types.include?(:browser) || types.include?("browser")

          driver.logs.get(:browser).map do |entry|
            {
              timestamp: entry.timestamp,
              level: entry.level,
              message: entry.message.to_s.byteslice(0, 2000)
            }
          end.last(200)
        end
      end

      def capture_selenium_performance_logs(driver)
        safe_driver_value(driver) do
          next nil unless driver.respond_to?(:logs)
          types = driver.logs.available_types
          next nil unless types.include?(:performance) || types.include?("performance")

          driver.logs.get(:performance).map do |entry|
            { timestamp: entry.timestamp, message: entry.message.to_s.byteslice(0, 20_000) }
          end.last(300)
        end
      end

      # --- Playwright log extractors (Phase 3 port) ------------------------

      def capture_playwright_browser_logs(page)
        instrumentation = page_instrumentation_for(page)
        return nil unless instrumentation

        instrumentation.selenium_shaped_browser_entries.last(200)
      end

      def capture_playwright_performance_logs(page)
        instrumentation = page_instrumentation_for(page)
        return nil unless instrumentation

        instrumentation.selenium_shaped_performance_entries.last(300)
      end

      def page_instrumentation_for(page)
        return nil unless page.respond_to?(:instrumentation)

        page.instrumentation
      rescue StandardError
        nil
      end
    end
  end
end
