require "fileutils"
require "json"
require "set"
require "time"
require "uri"
require "selenium-webdriver"

module Diagnostics
  class SeleniumUiAudit
    SAFE_BUTTON_DENYLIST = /(delete|destroy|clear|stop all|force|retry all|wipe|remove|drop|truncate|reset|background|run all tests|object detection|face detection|face embedding|face comparison|refresh status|manual browser login|validate session|export stored cookies|import cookies|sync followers|sync following|download archives|run archive)/i

    def initialize(base_url:, routes:, max_actions: 12, wait_seconds: 16, include_table_actions: false, include_nav_actions: false, output_dir: nil)
      @base_url = base_url
      @routes = Array(routes).map { |route| absolute_url(route) }.uniq
      @max_actions = Integer(max_actions)
      @wait_seconds = Integer(wait_seconds)
      @include_table_actions = include_table_actions
      @include_nav_actions = include_nav_actions
      @output_dir = output_dir || default_output_dir
      FileUtils.mkdir_p(@output_dir)
      @pages = []
      @issues = []
    end

    def run!
      started_at = Time.now.utc
      driver = build_driver

      @routes.each do |route|
        @pages << audit_route(driver, route)
      end

      @issues = @pages.flat_map { |page| page[:issues] }
      finished_at = Time.now.utc
      report = {
        started_at: started_at.iso8601,
        finished_at: finished_at.iso8601,
        duration_seconds: (finished_at - started_at).round(2),
        base_url: @base_url,
        routes: @routes,
        pages: @pages,
        issues: @issues,
        totals: {
          visited_pages: @pages.size,
          errors: @issues.count { |row| row[:severity] == "error" },
          warnings: @issues.count { |row| row[:severity] == "warning" },
        },
      }

      File.write(File.join(@output_dir, "report.json"), JSON.pretty_generate(report))
      report
    ensure
      driver&.quit
    end

    private

    def build_driver
      options = Selenium::WebDriver::Chrome::Options.new
      options.add_argument("--headless=new")
      options.add_argument("--disable-gpu")
      options.add_argument("--no-sandbox")
      options.add_argument("--disable-dev-shm-usage")
      options.add_argument("--window-size=1920,1080")
      options.page_load_strategy = "eager"
      options.add_option("goog:loggingPrefs", { browser: "ALL" })

      driver = Selenium::WebDriver.for(:chrome, options: options)
      driver.manage.timeouts.page_load = @wait_seconds * 3
      driver.manage.timeouts.script = @wait_seconds
      driver
    end

    def absolute_url(path_or_url)
      return path_or_url if path_or_url.to_s.start_with?("http://", "https://")

      URI.join(@base_url, path_or_url.to_s).to_s
    end

    def default_output_dir
      run_id = Time.now.utc.strftime("%Y%m%d_%H%M%S")
      File.expand_path("tmp/diagnostic_specs/ui_audit/#{run_id}", Dir.pwd)
    end

    def audit_route(driver, route)
      page = {
        route: route,
        title: nil,
        actions: [],
        issues: [],
        screenshot: nil,
      }

      attempts = 0
      begin
      driver.navigate.to(route)
      wait_for_document(driver)
      install_runtime_probe(driver)
      wait_for_async_settle(driver)
      page[:title] = driver.title

      ensure_js_responsive(driver, page, "page_ready")

      build_actions(driver).first(@max_actions).each do |action|
        run_action(driver, page, action, route)
      end

      collect_logs(driver, page, "page_idle")
      page
    rescue StandardError => e
      if transient_navigation_error?(e) && attempts < 1
        attempts += 1
        sleep 0.4
        retry
      end
      page[:issues] << issue(route, "page_load", "error", "page_load_error", e.message)
      page
    ensure
      begin
        shot_name = "page_#{sanitize(route)}.png"
        driver.save_screenshot(File.join(@output_dir, shot_name))
        page[:screenshot] = shot_name
      rescue StandardError
        page[:screenshot] = nil
      end
    end
    end

    def transient_navigation_error?(error)
      message = String(error&.message || "").downcase
      message.include?("timed out receiving message from renderer") || message.include?("timeout")
    end

    def wait_for_document(driver)
      Selenium::WebDriver::Wait.new(timeout: @wait_seconds).until do
        state = driver.execute_script("return document.readyState")
        %w[interactive complete].include?(state)
      end
    end

    def install_runtime_probe(driver)
      driver.execute_script(<<~JS)
        if (!window.__diagProbeInstalled) {
          window.__diagProbeInstalled = true
          window.__diagPendingFetch = 0
          window.__diagPendingXhr = 0
          window.__diagPayload = { uncaught: [], rejections: [], failedRequests: [] }

          window.addEventListener("error", (event) => {
            window.__diagPayload.uncaught.push({
              message: event?.message || "Unknown error",
              source: event?.filename || "",
              line: event?.lineno || 0,
              col: event?.colno || 0
            })
          })

          window.addEventListener("unhandledrejection", (event) => {
            const reason = event?.reason?.message || event?.reason || "Unhandled rejection"
            window.__diagPayload.rejections.push({ reason: String(reason) })
          })

          if (!window.__diagFetchWrapped && window.fetch) {
            window.__diagFetchWrapped = true
            const originalFetch = window.fetch.bind(window)
            window.fetch = async (...args) => {
              const req = args[0]
              const url = typeof req === "string" ? req : (req?.url || "unknown")
              window.__diagPendingFetch += 1
              try {
                const response = await originalFetch(...args)
                if (!response.ok) {
                  window.__diagPayload.failedRequests.push({
                    type: "fetch",
                    url,
                    status: response.status,
                    statusText: response.statusText || "",
                  })
                }
                return response
              } catch (error) {
                window.__diagPayload.failedRequests.push({
                  type: "fetch",
                  url,
                  status: 0,
                  statusText: error?.message || "network error",
                })
                throw error
              } finally {
                window.__diagPendingFetch = Math.max(0, window.__diagPendingFetch - 1)
              }
            }
          }
        }
      JS
    end

    def wait_for_async_settle(driver)
      driver.execute_async_script(<<~JS)
        const done = arguments[0]
        const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms))
        const run = async () => {
          for (let i = 0; i < 8; i += 1) {
            const pendingFetch = Number(window.__diagPendingFetch || 0) > 0
            const pendingXhr = Number(window.__diagPendingXhr || 0) > 0
            if (!pendingFetch && !pendingXhr) {
              await sleep(100)
              done(true)
              return
            }
            await sleep(180)
          }
          done(false)
        }
        run().catch(() => done(false))
      JS
    rescue StandardError
      nil
    end

    def build_actions(driver)
      current_url = canonicalize(driver.current_url)
      actions = []
      if @include_nav_actions
        actions.concat(collect_click_actions(driver, "a.sidebar-link, a.topbar-shortcut-link", :nav_click, current_url))
      end
      actions.concat(collect_click_actions(driver, "button[data-bs-toggle='modal']", :open_modal, current_url))
      actions.concat(collect_click_actions(driver, "button.story-preview-button, button[data-action='profile-post-modal#open']", :open_profile_modal, current_url))
      if @include_table_actions
        actions.concat(collect_click_actions(driver, ".tabulator-col[tabulator-field]", :sort_column, current_url).first(1))
        actions.concat(collect_click_actions(driver, ".tabulator-page", :paginate, current_url).first(1))
      end
      actions.concat(collect_click_actions(driver, "button.btn, a.btn", :generic_click, current_url))
      actions.uniq { |row| row[:key] }
    end

    def collect_click_actions(driver, selector, kind, current_url)
      nodes = driver.execute_script(<<~JS, selector)
        const selector = arguments[0]
        const nodes = Array.from(document.querySelectorAll(selector))
        return nodes.map((el, index) => {
          const rect = el.getBoundingClientRect()
          const tag = el.tagName.toLowerCase()
          return {
            index,
            text: (el.textContent || "").trim().replace(/\\s+/g, " "),
            disabled: el.matches(":disabled") || el.getAttribute("aria-disabled") === "true",
            visible: rect.width > 0 && rect.height > 0,
            href: tag === "a" ? (el.getAttribute("href") || "") : "",
            target: tag === "a" ? (el.getAttribute("target") || "") : "",
            tag,
            id: el.id || "",
            action: el.getAttribute("data-action") || "",
          }
        })
      JS

      Array(nodes).filter_map do |node|
        next unless node["visible"]
        next if node["disabled"]
        next if node["target"].to_s.strip.downcase == "_blank"

        text = node["text"].to_s
        next if text.match?(SAFE_BUTTON_DENYLIST)
        next if node["tag"] == "a" && text.empty?

        href = node["href"].to_s
        if href.length > 0
          next if href.start_with?("javascript:", "mailto:", "tel:")
          next if canonicalize(absolute_url(href)) == current_url
        end

        {
          kind: kind,
          selector: selector,
          index: node["index"],
          label: text.empty? ? node["tag"].to_s : text,
          key: [kind, selector, node["index"], text, href, node["id"], node["action"]].join("|"),
        }
      end
    rescue StandardError
      []
    end

    def run_action(driver, page, action, expected_route)
      name = "#{action[:kind]}: #{action[:label]}"
      begin
        clicked = driver.execute_script(<<~JS, action[:selector], action[:index])
          const selector = arguments[0]
          const index = Number(arguments[1])
          const nodes = Array.from(document.querySelectorAll(selector))
          const el = nodes[index]
          if (!el) return { ok: false, reason: "missing" }
          const rect = el.getBoundingClientRect()
          if (rect.width <= 0 || rect.height <= 0) return { ok: false, reason: "not_visible" }
          el.scrollIntoView({ block: "center", inline: "center" })
          el.click()
          return { ok: true }
        JS

        unless clicked.is_a?(Hash) && clicked["ok"] == true
          page[:actions] << { action: name, status: "skipped", reason: clicked.is_a?(Hash) ? clicked["reason"].to_s : "unknown" }
          return
        end

        wait_for_async_settle(driver)
        close_open_dialogs(driver)
        collect_logs(driver, page, name)
        ensure_js_responsive(driver, page, name)

        page[:actions] << { action: name, status: "ok", url: canonicalize(driver.current_url) }

        if canonicalize(driver.current_url) != canonicalize(expected_route)
          driver.navigate.to(expected_route)
          wait_for_document(driver)
          install_runtime_probe(driver)
          wait_for_async_settle(driver)
        end
      rescue StandardError => e
        page[:actions] << { action: name, status: "failed", error: e.message, url: canonicalize(driver.current_url) }
        page[:issues] << issue(page[:route], name, "error", "action_error", e.message)
      end
    end

    def close_open_dialogs(driver)
      driver.execute_script(<<~JS)
        document.querySelectorAll("dialog[open]").forEach((dialog) => {
          const closeBtn = dialog.querySelector("button[data-action$='#close'], .modal-close, button.btn")
          if (closeBtn) {
            closeBtn.click()
          } else if (typeof dialog.close === "function") {
            try { dialog.close() } catch (_) {}
          }
        })

        document.querySelectorAll(".modal.show").forEach((modal) => {
          const closeBtn = modal.querySelector('[data-bs-dismiss="modal"], .btn-close')
          if (closeBtn) closeBtn.click()
        })
      JS
    rescue StandardError
      nil
    end

    def ensure_js_responsive(driver, page, action_name)
      result = driver.execute_async_script(<<~JS)
        const done = arguments[0]
        Promise.resolve().then(() => {
          window.requestAnimationFrame(() => done({ ok: true }))
        }).catch((error) => done({ ok: false, message: error?.message || "ui probe failed" }))
      JS
      return if result.is_a?(Hash) && result["ok"] == true

      detail = result.is_a?(Hash) ? result["message"].to_s : "ui thread probe failed"
      page[:issues] << issue(page[:route], action_name, "error", "ui_thread_unresponsive", detail)
    rescue Selenium::WebDriver::Error::ScriptTimeoutError => e
      page[:issues] << issue(page[:route], action_name, "error", "ui_thread_unresponsive", e.message)
    end

    def collect_logs(driver, page, action_name)
      browser_logs = []
      browser = driver
      if browser.respond_to?(:logs)
        browser_logs = browser.logs.get(:browser)
      elsif browser.respond_to?(:manage) && browser.manage.respond_to?(:logs)
        browser_logs = browser.manage.logs.get(:browser)
      end

      browser_logs.each do |entry|
        level = entry.level.to_s.upcase
        detail = entry.message.to_s
        next if detail.empty?
        next unless level == "SEVERE" || level == "WARNING"
        next if benign_console_noise?(detail)

        severity = level == "SEVERE" ? "error" : "warning"
        type = detail.include?("Uncaught") ? "uncaught_exception" : "console_#{level.downcase}"
        page[:issues] << issue(page[:route], action_name, severity, type, detail)
      end

      probe = driver.execute_script(<<~JS)
        const payload = window.__diagPayload || { uncaught: [], rejections: [], failedRequests: [] }
        const copy = {
          uncaught: [...payload.uncaught],
          rejections: [...payload.rejections],
          failedRequests: [...payload.failedRequests]
        }
        payload.uncaught.length = 0
        payload.rejections.length = 0
        payload.failedRequests.length = 0
        return copy
      JS

      Array(probe["uncaught"]).each do |err|
        detail = "#{err['message']} #{err['source']}:#{err['line']}:#{err['col']}".strip
        next if benign_abort_message?(detail)

        page[:issues] << issue(page[:route], action_name, "error", "uncaught_exception", detail)
      end

      Array(probe["rejections"]).each do |err|
        detail = err["reason"].to_s
        next if benign_abort_message?(detail)

        page[:issues] << issue(page[:route], action_name, "error", "unhandled_rejection", detail)
      end

      Array(probe["failedRequests"]).each do |req|
        detail = "#{req['type']} #{req['url']} -> #{req['status']} #{req['statusText']}".strip
        status_text = req["statusText"].to_s.downcase
        next if req["status"].to_i.zero? && status_text.match?(/abort|aborted|cancel|canceled|cancelled/)

        severity = req["status"].to_i >= 500 || req["status"].to_i.zero? ? "error" : "warning"
        page[:issues] << issue(page[:route], action_name, severity, "failed_request", detail)
      end

      dedupe!(page)
    rescue StandardError => e
      page[:issues] << issue(page[:route], action_name, "warning", "log_collection_failed", e.message)
      dedupe!(page)
    end

    def issue(page_url, action, severity, type, detail)
      {
        page_url: page_url,
        action: action,
        severity: severity,
        type: type,
        detail: detail,
      }
    end

    def dedupe!(page)
      seen = Set.new
      page[:issues] = page[:issues].select do |row|
        key = [row[:severity], row[:type], row[:detail]].join("|")
        next false if seen.include?(key)
        seen << key
        true
      end
    end

    def benign_abort_message?(detail)
      text = detail.to_s
      return false if text.empty?

      text.match?(/the user aborted a request/i) ||
        text.match?(/\babort(?:ed|error)?\b/i) ||
        text.match?(/data load error: .*failed to fetch/i)
    end

    def benign_console_noise?(detail)
      text = detail.to_s
      return false if text.empty?

      benign_abort_message?(text) ||
        text.match?(%r{/favicon\.ico .*failed to load resource}i)
    end

    def canonicalize(url)
      uri = URI.parse(url.to_s)
      uri.fragment = nil
      uri.to_s
    rescue URI::InvalidURIError
      url.to_s
    end

    def sanitize(value)
      value.to_s.gsub(%r{[^a-zA-Z0-9\-]+}, "-").gsub(/-+/, "-").gsub(/^-|-$/, "")
    end
  end
end
