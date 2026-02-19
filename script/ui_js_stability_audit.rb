#!/usr/bin/env ruby
# frozen_string_literal: true

require "fileutils"
require "json"
require "set"
require "time"
require "uri"
require "selenium-webdriver"

class UiJsStabilityAudit
  SAFE_BUTTON_DENYLIST = /(delete|destroy|clear|stop all|force|retry all|wipe|remove|drop|truncate|reset|background)/i
  SAFE_LINK_DENYLIST = /(logout|sign out|delete|destroy)/i
  MAX_ACTIONS_PER_PAGE = Integer(ENV.fetch("UI_AUDIT_MAX_ACTIONS_PER_PAGE", "20"))
  MAX_DISCOVERED_LINKS_PER_PAGE = Integer(ENV.fetch("UI_AUDIT_MAX_LINKS_PER_PAGE", "40"))
  WAIT_SECONDS = Integer(ENV.fetch("UI_AUDIT_WAIT_SECONDS", "30"))

  SEED_ROUTES = [
    "/",
    "/instagram_accounts",
    "/instagram_profiles",
    "/instagram_posts",
    "/ai_dashboard",
    "/admin/background_jobs",
    "/admin/background_jobs/failures",
    "/admin/issues",
    "/admin/storage_ingestions"
  ].freeze

  def initialize
    @base_url = ENV.fetch("UI_AUDIT_BASE_URL", "http://127.0.0.1:3000")
    @base_uri = URI.parse(@base_url)
    @run_id = Time.now.utc.strftime("%Y%m%d_%H%M%S")
    @out_dir = File.expand_path("tmp/ui_audit/#{@run_id}", Dir.pwd)
    FileUtils.mkdir_p(@out_dir)
    @visited = Set.new
    @failures = []
    @warnings = []
    @report = {
      started_at: Time.now.utc.iso8601,
      base_url: @base_url,
      output_dir: @out_dir,
      pages: [],
      issues: []
    }
  end

  def run!
    driver = build_driver
    queue = discover_seed_urls

    until queue.empty?
      page_url = queue.shift
      next if @visited.include?(page_url)

      @visited << page_url
      page_result = audit_page(driver, page_url)
      @report[:pages] << page_result

      page_result[:issues].each do |issue|
        if issue[:severity] == "error"
          @failures << issue
        else
          @warnings << issue
        end
      end

      page_result[:discovered_links].each do |link|
        next if @visited.include?(link)
        queue << link unless queue.include?(link)
      end
    end

    @report[:finished_at] = Time.now.utc.iso8601
    @report[:totals] = {
      visited_pages: @report[:pages].size,
      errors: @failures.size,
      warnings: @warnings.size
    }
    @report[:issues] = (@failures + @warnings)

    report_path = File.join(@out_dir, "report.json")
    File.write(report_path, JSON.pretty_generate(@report))

    puts "UI JS stability report: #{report_path}"
    puts "Visited pages: #{@report[:totals][:visited_pages]}"
    puts "Errors: #{@report[:totals][:errors]}"
    puts "Warnings: #{@report[:totals][:warnings]}"

    exit(1) if @failures.any?
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
    driver.manage.timeouts.page_load = WAIT_SECONDS * 4
    driver
  end

  def discover_seed_urls
    SEED_ROUTES.map { |route| absolute_url(route) }
  end

  def absolute_url(path)
    URI.join(@base_url, path).to_s
  end

  def audit_page(driver, url)
    puts "[ui-audit] page #{url}"

    page = {
      page_url: url,
      title: nil,
      actions: [],
      issues: [],
      discovered_links: [],
      screenshot: nil
    }

    begin
      driver.navigate.to(url)
      wait_for_document(driver)
      install_runtime_probe(driver)
      wait_for_async_settle(driver)
      wait_for_tabulator_content(driver)
      page[:title] = driver.title
      ensure_js_responsive(driver, page, action_name: "page_ready")
      page[:discovered_links] = discover_links(driver)

      actions = build_actions(driver)
      actions.first(MAX_ACTIONS_PER_PAGE).each_with_index do |action, idx|
        run_action(driver, page, action, idx + 1)
      end

      collect_logs(driver, page, action_name: "page_idle")
    rescue StandardError => e
      page[:issues] << issue_payload(url, "page_load", "error", "page_load_error", e.message)
    ensure
      filename = "page_#{sanitize_filename(url)}.png"
      screenshot_path = File.join(@out_dir, filename)
      begin
        driver.save_screenshot(screenshot_path)
        page[:screenshot] = filename
      rescue StandardError
        page[:screenshot] = nil
      end
    end

    page
  end

  def wait_for_document(driver)
    Selenium::WebDriver::Wait.new(timeout: WAIT_SECONDS).until do
      state = driver.execute_script("return document.readyState")
      %w[interactive complete].include?(state)
    end
  end

  def wait_for_async_settle(driver)
    driver.execute_script(<<~JS)
      if (!window.__uiAuditWaitForQuiet) {
        window.__uiAuditWaitForQuiet = async function() {
          const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms))
          for (let i = 0; i < 8; i += 1) {
            const pendingTurbo = Array.from(document.querySelectorAll("turbo-frame[src]")).some((f) => f.hasAttribute("busy"))
            const pendingFetch = Number(window.__uiAuditPendingFetches || 0) > 0
            const pendingXhr = Number(window.__uiAuditPendingXhrs || 0) > 0
            if (!pendingTurbo && !pendingFetch && !pendingXhr) {
              await sleep(120)
              return true
            }
            await sleep(200)
          }
          return false
        }
      }
    JS

    driver.execute_async_script(<<~JS)
      const done = arguments[0]
      if (window.__uiAuditWaitForQuiet) {
        window.__uiAuditWaitForQuiet().then(() => done(true)).catch(() => done(false))
      } else {
        setTimeout(() => done(true), 250)
      }
    JS
  rescue StandardError
    nil
  end

  def install_runtime_probe(driver)
    driver.execute_script(<<~JS)
      if (!window.__uiAuditProbeInstalled) {
        window.__uiAuditProbeInstalled = true
        window.__uiAuditPendingFetches = 0
        window.__uiAuditPendingXhrs = 0
        window.__uiAuditCaptured = {
          uncaught: [],
          rejections: [],
          failedRequests: []
        }

        window.addEventListener("error", (event) => {
          const payload = {
            message: event?.message || "Unknown error",
            source: event?.filename || "",
            line: event?.lineno || 0,
            col: event?.colno || 0
          }
          window.__uiAuditCaptured.uncaught.push(payload)
        })

        window.addEventListener("unhandledrejection", (event) => {
          let reason = "Unhandled rejection"
          try {
            if (event && event.reason) {
              if (typeof event.reason === "string") {
                reason = event.reason
              } else if (event.reason.message) {
                reason = event.reason.message
              } else {
                reason = JSON.stringify(event.reason)
              }
            }
          } catch (_err) {
            reason = "Unhandled rejection (unserializable)"
          }
          window.__uiAuditCaptured.rejections.push({ reason })
        })

        if (!window.__uiAuditFetchWrapped && window.fetch) {
          window.__uiAuditFetchWrapped = true
          const originalFetch = window.fetch.bind(window)
          window.fetch = async (...args) => {
            const req = args[0]
            const url = typeof req === "string" ? req : (req && req.url ? req.url : "unknown")
            window.__uiAuditPendingFetches += 1
            try {
              const response = await originalFetch(...args)
              if (!response.ok) {
                window.__uiAuditCaptured.failedRequests.push({
                  type: "fetch",
                  url,
                  status: response.status,
                  statusText: response.statusText || ""
                })
              }
              return response
            } catch (error) {
              window.__uiAuditCaptured.failedRequests.push({
                type: "fetch",
                url,
                status: 0,
                statusText: error?.message || "network error"
              })
              throw error
            } finally {
              window.__uiAuditPendingFetches = Math.max(0, window.__uiAuditPendingFetches - 1)
            }
          }
        }

        if (!window.__uiAuditXhrWrapped && window.XMLHttpRequest) {
          window.__uiAuditXhrWrapped = true
          const OriginalXhr = window.XMLHttpRequest
          window.XMLHttpRequest = function WrappedXhr() {
            const xhr = new OriginalXhr()
            let requestUrl = ""
            let tracked = false

            const originalOpen = xhr.open
            xhr.open = function(method, url, ...rest) {
              requestUrl = String(url || "")
              return originalOpen.call(this, method, url, ...rest)
            }

            const originalSend = xhr.send
            xhr.send = function(...args) {
              tracked = true
              window.__uiAuditPendingXhrs += 1

              const finalize = () => {
                if (!tracked) return
                tracked = false
                window.__uiAuditPendingXhrs = Math.max(0, window.__uiAuditPendingXhrs - 1)
              }

              xhr.addEventListener("loadend", () => {
                if (xhr.status >= 400 || xhr.status === 0) {
                  window.__uiAuditCaptured.failedRequests.push({
                    type: "xhr",
                    url: requestUrl,
                    status: xhr.status,
                    statusText: xhr.statusText || ""
                  })
                }
                finalize()
              }, { once: true })

              xhr.addEventListener("error", () => {
                window.__uiAuditCaptured.failedRequests.push({
                  type: "xhr",
                  url: requestUrl,
                  status: 0,
                  statusText: "xhr error"
                })
                finalize()
              }, { once: true })

              return originalSend.apply(this, args)
            }

            return xhr
          }
        }
      }
    JS
  end

  def discover_links(driver)
    raw = driver.execute_script(<<~JS)
      const sameOrigin = window.location.origin
      const links = Array.from(document.querySelectorAll("a[href]"))
      const out = []
      for (const el of links) {
        const href = (el.getAttribute("href") || "").trim()
        if (!href || href.startsWith("javascript:") || href.startsWith("mailto:") || href.startsWith("tel:")) continue
        const text = (el.textContent || "").trim()
        const abs = new URL(href, window.location.href)
        if (abs.origin !== sameOrigin) continue
        if (abs.pathname.startsWith("/rails/active_storage/")) continue
        if (abs.pathname.startsWith("/cable")) continue
        out.push({ href: abs.href, text, classes: el.className || "" })
      }
      out
    JS

    scored = raw
      .select { |row| row.is_a?(Hash) && row["href"].is_a?(String) }
      .reject { |row| row["text"].to_s.match?(SAFE_LINK_DENYLIST) }
      .map do |row|
        href = canonicalize_url(row["href"])
        classes = row["classes"].to_s
        nav_like = classes.match?(/sidebar-link|topbar-shortcut|quick-action/i)
        [href, nav_like ? 1 : 0, url_depth(href)]
      end
      .uniq { |(href, _priority, _depth)| href }
      .sort_by { |_href, priority, depth| [priority, -depth] }

    scored.first(MAX_DISCOVERED_LINKS_PER_PAGE).map(&:first)
  rescue StandardError
    []
  end

  def build_actions(driver)
    actions = []
    current_url = canonicalize_url(driver.current_url)

    actions += collect_click_actions(driver, "a.sidebar-link, a.topbar-shortcut-link", :nav_click, current_url: current_url).first(2)
    actions += collect_click_actions(driver, "button[data-bs-toggle='modal']", :open_modal, current_url: current_url).first(3)
    actions += collect_click_actions(driver, "button[data-action$='#open']", :open_dialog, current_url: current_url).first(3)
    actions += collect_click_actions(driver, "button.story-preview-button", :open_story_preview, current_url: current_url).first(3)
    actions += collect_click_actions(driver, "button[data-action='profile-post-modal#open']", :open_profile_post_modal, current_url: current_url).first(3)
    actions += collect_click_actions(driver, ".tabulator-page", :paginate, current_url: current_url).first(1)
    actions += collect_click_actions(driver, ".tabulator-col[tabulator-field]", :sort_column, current_url: current_url).first(1)
    actions += collect_click_actions(driver, "button.btn, a.btn", :generic_click, current_url: current_url).first(8)

    actions.uniq { |a| a[:key] }
  end

  def collect_click_actions(driver, selector, kind, current_url:)
    nodes = driver.execute_script(<<~JS, selector)
      const selector = arguments[0]
      const items = Array.from(document.querySelectorAll(selector))
      return items.map((el, idx) => {
        const text = (el.textContent || "").trim().replace(/\s+/g, " ")
        const disabled = el.matches(":disabled") || el.getAttribute("aria-disabled") === "true"
        const rect = el.getBoundingClientRect()
        const visible = rect.width > 0 && rect.height > 0
        const href = el.tagName.toLowerCase() === "a" ? (el.getAttribute("href") || "") : ""
        const action = el.getAttribute("data-action") || ""
        return {
          index: idx,
          text,
          disabled,
          visible,
          href,
          action,
          id: el.id || "",
          cls: el.className || "",
          tag: el.tagName.toLowerCase()
        }
      })
    JS

    nodes.each_with_index.filter_map do |node, idx|
      next unless node["visible"]
      next if node["disabled"]
      text = node["text"].to_s
      next if text.match?(SAFE_BUTTON_DENYLIST)
      next if text.match?(/\A[a-zA-Z]\z/) && node["tag"].to_s == "a"
      next if text.empty? && node["tag"].to_s == "a"

      href = node["href"].to_s
      if !href.empty?
        next if href.start_with?("mailto:", "tel:", "javascript:")
        next if canonicalize_url(absolute_url(href)) == current_url
      end

      key = [kind, selector, idx, text, href, node["action"], node["id"]].join("|")
      {
        kind: kind,
        selector: selector,
        index: idx,
        label: text.empty? ? node["tag"] : text,
        key: key
      }
    end
  rescue StandardError
    []
  end

  def run_action(driver, page, action, ordinal)
    action_name = "#{action[:kind]}: #{action[:label]}"
    puts "  [action #{ordinal}] #{action_name}"
    expected_url = canonicalize_url(page[:page_url])

    begin
      if action[:kind] == :sort_column || action[:kind] == :paginate || action[:kind] == :nav_click
        wait_for_tabulator_content(driver)
        sleep 0.9
      end
      click_result = perform_click_action(driver, action)
      unless click_result[:ok]
        page[:actions] << {
          action: action_name,
          status: "skipped",
          reason: click_result[:reason],
          url: canonicalize_url(driver.current_url)
        }
        return
      end
      wait_for_async_settle(driver)
      exercise_media(driver)
      close_open_dialogs(driver)
      collect_logs(driver, page, action_name: action_name)
      ensure_js_responsive(driver, page, action_name: action_name)

      page[:actions] << {
        action: action_name,
        status: "ok",
        url: canonicalize_url(driver.current_url)
      }

      # Keep actions isolated per page. If an action navigates away, return.
      if canonicalize_url(driver.current_url) != expected_url
        driver.navigate.to(expected_url)
        wait_for_document(driver)
        install_runtime_probe(driver)
        wait_for_async_settle(driver)
        wait_for_tabulator_content(driver)
      end
    rescue StandardError => e
      issue = issue_payload(page[:page_url], action_name, "error", "action_error", e.message)
      page[:issues] << issue
      page[:actions] << {
        action: action_name,
        status: "failed",
        error: e.message,
        url: canonicalize_url(driver.current_url)
      }
    end
  end

  def perform_click_action(driver, action)
    clicked = driver.execute_script(<<~JS, action[:selector], action[:index])
      const selector = arguments[0]
      const index = Number(arguments[1])
      const elements = Array.from(document.querySelectorAll(selector))
      const el = elements[index]
      if (!el) return { ok: false, reason: "missing" }

      const rect = el.getBoundingClientRect()
      if (rect.width <= 0 || rect.height <= 0) return { ok: false, reason: "not_visible" }

      el.scrollIntoView({ block: "center", inline: "center" })
      el.click()
      return { ok: true }
    JS

    return { ok: true } if clicked.is_a?(Hash) && clicked["ok"]

    { ok: false, reason: clicked.is_a?(Hash) ? clicked["reason"].to_s : "unknown" }
  end

  def wait_for_tabulator_content(driver)
    driver.execute_async_script(<<~JS)
      const done = arguments[0]
      const ready = () => {
        const tables = Array.from(document.querySelectorAll(".tabulator"))
        if (!tables.length) return true

        return tables.every((table) => {
          const hasRows = table.querySelectorAll(".tabulator-row").length > 0
          const placeholder = table.querySelector(".tabulator-placeholder")
          const hasPlaceholder = !!placeholder && (placeholder.textContent || "").trim().length > 0
          const loader = table.querySelector(".tabulator-loader")
          const loaderVisible = !!loader && (() => {
            const style = window.getComputedStyle(loader)
            return style.display !== "none" && style.visibility !== "hidden" && loader.offsetParent !== null
          })()

          return (hasRows || hasPlaceholder) && !loaderVisible
        })
      }

      let attempts = 0
      const poll = () => {
        if (ready()) {
          done(true)
          return
        }
        attempts += 1
        if (attempts > 18) {
          done(false)
          return
        }
        setTimeout(poll, 180)
      }

      poll()
    JS
  rescue StandardError
    nil
  end

  def exercise_media(driver)
    driver.execute_script(<<~JS)
      const videos = Array.from(document.querySelectorAll("video"))
      videos.slice(0, 2).forEach((video) => {
        try {
          if (video.readyState === 0 && video.preload === "none") {
            video.preload = "metadata"
          }
          const playPromise = video.play()
          if (playPromise && typeof playPromise.catch === "function") {
            playPromise.catch(() => {})
          }
          setTimeout(() => {
            try { video.pause() } catch (_e) {}
          }, 120)
        } catch (_e) {
          // Captured via global error probe when relevant.
        }
      })
    JS
  rescue StandardError
    nil
  end

  def close_open_dialogs(driver)
    driver.execute_script(<<~JS)
      document.querySelectorAll("dialog[open]").forEach((dialog) => {
        const closeBtn = dialog.querySelector("button[data-action$='#close'], button.btn")
        if (closeBtn) {
          closeBtn.click()
        } else {
          try { dialog.close() } catch (_e) {}
        }
      })

      const bootstrapModals = Array.from(document.querySelectorAll('.modal.show'))
      bootstrapModals.forEach((modalEl) => {
        const closeBtn = modalEl.querySelector('[data-bs-dismiss="modal"], .btn-close')
        if (closeBtn) closeBtn.click()
      })
    JS
  rescue StandardError
    nil
  end

  def collect_logs(driver, page, action_name:)
    browser_logs = driver.logs.get(:browser)
    browser_logs.each do |entry|
      level = entry.level.to_s.upcase
      msg = entry.message.to_s
      next if msg.empty?

      severity = if level == "SEVERE"
        "error"
      elsif level == "WARNING"
        "warning"
      else
        nil
      end
      next unless severity

      type = if msg.include?("Failed to load resource")
        "failed_resource"
      elsif msg.include?("Uncaught")
        "uncaught_exception"
      else
        "console_#{level.downcase}"
      end

      page[:issues] << issue_payload(page[:page_url], action_name, severity, type, msg)
    end

    probe = driver.execute_script(<<~JS)
      const payload = window.__uiAuditCaptured || { uncaught: [], rejections: [], failedRequests: [] }
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
      page[:issues] << issue_payload(page[:page_url], action_name, "error", "uncaught_exception", detail)
    end

    Array(probe["rejections"]).each do |rej|
      detail = rej["reason"].to_s
      page[:issues] << issue_payload(page[:page_url], action_name, "error", "unhandled_rejection", detail)
    end

    Array(probe["failedRequests"]).each do |req|
      detail = "#{req['type']} #{req['url']} -> #{req['status']} #{req['statusText']}".strip
      status_text = req["statusText"].to_s.downcase
      if req["status"].to_i.zero? && status_text.match?(/abort|aborted|signal is aborted|canceled|cancelled/)
        next
      end
      severity = req["status"].to_i >= 500 || req["status"].to_i.zero? ? "error" : "warning"
      page[:issues] << issue_payload(page[:page_url], action_name, severity, "failed_request", detail)
    end

    dedupe_page_issues!(page)
  end

  def ensure_js_responsive(driver, page, action_name:)
    result = driver.execute_async_script(<<~JS)
      const done = arguments[0]
      const startedAt = Date.now()
      try {
        Promise.resolve().then(() => {
          window.requestAnimationFrame(() => {
            done({ ok: true, elapsedMs: Date.now() - startedAt })
          })
        })
      } catch (error) {
        done({ ok: false, message: error?.message || "js responsiveness check failed" })
      }
    JS

    unless result.is_a?(Hash) && result["ok"] == true
      detail = result.is_a?(Hash) ? result["message"].to_s : "js responsiveness check failed"
      page[:issues] << issue_payload(page[:page_url], action_name, "error", "ui_thread_unresponsive", detail)
      dedupe_page_issues!(page)
    end
  rescue Selenium::WebDriver::Error::ScriptTimeoutError => e
    page[:issues] << issue_payload(page[:page_url], action_name, "error", "ui_thread_unresponsive", e.message)
    dedupe_page_issues!(page)
  rescue StandardError => e
    page[:issues] << issue_payload(page[:page_url], action_name, "warning", "ui_thread_probe_failed", e.message)
    dedupe_page_issues!(page)
  end

  def issue_payload(page_url, action, severity, type, detail)
    {
      page_url: page_url,
      action: action,
      severity: severity,
      type: type,
      detail: detail
    }
  end

  def dedupe_page_issues!(page)
    seen = Set.new
    page[:issues] = page[:issues].filter do |issue|
      key = [issue[:severity], issue[:type], issue[:detail]].join("|")
      next false if seen.include?(key)

      seen << key
      true
    end
  end

  def canonicalize_url(url)
    uri = URI.parse(url)
    uri.fragment = nil
    uri.to_s
  rescue URI::InvalidURIError
    url
  end

  def url_depth(url)
    uri = URI.parse(url)
    uri.path.split("/").reject(&:empty?).size
  rescue URI::InvalidURIError
    0
  end

  def sanitize_filename(value)
    value.gsub(%r{[^a-zA-Z0-9\-]+}, "-").gsub(/-+/, "-").gsub(/^-|-$/, "")
  end
end

UiJsStabilityAudit.new.run!
