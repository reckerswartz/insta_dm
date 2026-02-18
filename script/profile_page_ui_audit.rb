#!/usr/bin/env ruby

require "fileutils"
require "json"
require "net/http"
require "selenium-webdriver"
require "time"
require "uri"

STDOUT.sync = true

class ProfilePageUiAudit
  VIEWPORTS = [
    { name: "desktop", width: 1600, height: 1000 },
    { name: "tablet", width: 1100, height: 900 }
  ].freeze

  WAIT_TIMEOUT = 24
  FRAME_WAIT_TIMEOUT = 12
  MAX_ACTIONS = ENV.fetch("PROFILE_UI_AUDIT_MAX_ACTIONS", "80").to_i.clamp(1, 220)

  def initialize
    @base_url = ENV.fetch("UI_BASE_URL", "http://127.0.0.1:3000")
    @account_id = ENV.fetch("PROFILE_UI_AUDIT_ACCOUNT_ID", "2")
    @forced_profile_path = ENV["PROFILE_UI_AUDIT_PROFILE_PATH"].to_s.strip

    timestamp = Time.now.utc.strftime("%Y%m%d_%H%M%S")
    @output_dir = File.join(Dir.pwd, "tmp", "profile_page_ui_audit", timestamp)
    FileUtils.mkdir_p(@output_dir)

    @report = {
      generated_at: Time.now.utc.iso8601,
      base_url: @base_url,
      account_id: @account_id,
      output_dir: @output_dir,
      runs: []
    }

    @driver = Selenium::WebDriver.for(:chrome, options: build_options)
    @driver.manage.timeouts.page_load = WAIT_TIMEOUT
    @driver.manage.timeouts.script_timeout = WAIT_TIMEOUT
  end

  def run
    ensure_server_online!
    install_probe_hooks
    profile_path = resolve_profile_path
    raise "Unable to resolve profile path." if profile_path.to_s.empty?

    puts "Profile page UI audit started for #{profile_path}"
    puts "Output directory: #{@output_dir}"

    VIEWPORTS.each do |viewport|
      puts "Running #{viewport[:name]} viewport (#{viewport[:width]}x#{viewport[:height]})..."
      @driver.manage.window.resize_to(viewport[:width], viewport[:height])
      @report[:runs] << run_for_viewport(profile_path: profile_path, viewport: viewport)
      write_report_snapshot!
    end

    write_report!
  ensure
    @driver&.quit
  end

  private

  def build_options
    options = Selenium::WebDriver::Chrome::Options.new
    options.add_argument("--headless=new") unless ENV["UI_HEADFUL"] == "1"
    options.add_argument("--disable-gpu")
    options.add_argument("--disable-dev-shm-usage")
    options.add_argument("--no-sandbox")
    options
  end

  def ensure_server_online!
    response = Net::HTTP.get_response(URI.join(@base_url, "/up"))
    return if response.code.to_i == 200

    raise "Health check failed at /up with status #{response.code}"
  rescue StandardError => e
    raise "Unable to connect to #{@base_url}: #{e.message}"
  end

  def install_probe_hooks
    @driver.execute_cdp(
      "Page.addScriptToEvaluateOnNewDocument",
      source: <<~JS
        (() => {
          window.__profileAudit = {
            startedAt: Date.now(),
            errors: [],
            networkFailures: [],
            frameLoads: [],
            frameErrors: [],
            longTaskCount: 0,
            longTaskTotalMs: 0,
            longTaskMaxMs: 0
          };

          const pushError = (msg) => {
            try { window.__profileAudit.errors.push(String(msg || "error")); } catch (_) {}
          };

          window.addEventListener("error", (event) => {
            pushError(`[error] ${event.message || "window_error"} ${event.filename || ""}`.trim());
          });

          window.addEventListener("unhandledrejection", (event) => {
            const reason = event.reason && event.reason.message ? event.reason.message : String(event.reason || "unhandled_rejection");
            pushError(`[promise] ${reason}`);
          });

          const originalFetch = window.fetch;
          if (typeof originalFetch === "function") {
            window.fetch = function(...args) {
              const req = args[0];
              const reqUrl = typeof req === "string" ? req : (req && req.url) || "";
              return originalFetch.apply(this, args)
                .then((resp) => {
                  if (!resp.ok) {
                    window.__profileAudit.networkFailures.push({ type: "fetch", url: String(reqUrl), status: Number(resp.status || 0), at: Date.now() });
                  }
                  return resp;
                })
                .catch((err) => {
                  const message = String(err && err.message || err || "");
                  if (!/aborted/i.test(message)) {
                    window.__profileAudit.networkFailures.push({ type: "fetch", url: String(reqUrl), status: 0, error: message, at: Date.now() });
                  }
                  throw err;
                });
            };
          }

          const originalOpen = XMLHttpRequest.prototype.open;
          const originalSend = XMLHttpRequest.prototype.send;
          XMLHttpRequest.prototype.open = function(method, url, ...rest) {
            this.__auditUrl = url;
            this.__auditMethod = method;
            return originalOpen.call(this, method, url, ...rest);
          };
          XMLHttpRequest.prototype.send = function(...args) {
            this.addEventListener("loadend", () => {
              const status = Number(this.status || 0);
              if (status >= 400) {
                window.__profileAudit.networkFailures.push({
                  type: "xhr",
                  method: String(this.__auditMethod || ""),
                  url: String(this.__auditUrl || ""),
                  status,
                  at: Date.now()
                });
              }
            });
            return originalSend.apply(this, args);
          };

          document.addEventListener("turbo:frame-load", (event) => {
            const frame = event.target;
            if (!(frame instanceof HTMLElement)) return;
            window.__profileAudit.frameLoads.push({
              id: frame.id || "",
              textPreview: String(frame.textContent || "").replace(/\\s+/g, " ").trim().slice(0, 120),
              at: Date.now()
            });
          });

          document.addEventListener("turbo:fetch-request-error", (event) => {
            const frame = event.target;
            if (!(frame instanceof HTMLElement)) return;
            const detail = event.detail || {};
            const response = detail.fetchResponse || {};
            window.__profileAudit.frameErrors.push({
              id: frame.id || "",
              status: Number(response.statusCode || 0),
              at: Date.now()
            });
          });

          if (window.PerformanceObserver && PerformanceObserver.supportedEntryTypes && PerformanceObserver.supportedEntryTypes.includes("longtask")) {
            const observer = new PerformanceObserver((list) => {
              for (const entry of list.getEntries()) {
                window.__profileAudit.longTaskCount += 1;
                window.__profileAudit.longTaskTotalMs += Number(entry.duration || 0);
                if (entry.duration > window.__profileAudit.longTaskMaxMs) {
                  window.__profileAudit.longTaskMaxMs = Number(entry.duration || 0);
                }
              }
            });
            observer.observe({ entryTypes: ["longtask"] });
          }
        })();
      JS
    )
  rescue StandardError => e
    puts "Warning: failed to install probe hooks: #{e.message}"
  end

  def resolve_profile_path
    if @forced_profile_path.start_with?("/instagram_profiles/")
      return @forced_profile_path
    end

    account_path = "/instagram_accounts/#{@account_id}"
    visit(account_path)
    wait_for_ready_state
    sleep(0.8)

    href = @driver.find_elements(css: "a[href^='/instagram_profiles/']")
                  .map { |el| el.attribute("href") }
                  .compact
                  .find { |value| URI(value).path.match?(%r{^/instagram_profiles/\d+$}) rescue false }

    href ? URI(href).path : nil
  end

  def run_for_viewport(profile_path:, viewport:)
    visit(profile_path)
    wait_for_profile_shell
    wait_for_profile_frames_loaded(timeout: FRAME_WAIT_TIMEOUT)
    sleep(0.9)

    run = {
      viewport: viewport,
      page: profile_path,
      baseline: screenshot("#{viewport[:name]}_baseline"),
      frame_steps: [],
      action_audit: {
        total_actions: 0,
        results: []
      }
    }

    [0, 20, 40, 60, 80, 100].each_with_index do |pct, idx|
      max_scroll = @driver.execute_script("return Math.max(document.body.scrollHeight, document.documentElement.scrollHeight) - window.innerHeight;").to_i
      target = ((max_scroll * pct) / 100.0).round
      @driver.execute_script("window.scrollTo({ top: arguments[0], behavior: 'instant' });", target)
      sleep(0.85)

      frame_state = collect_frame_state
      missing = frame_state.select { |row| !row["loaded"] }
      shot = screenshot("#{viewport[:name]}_step_#{idx}_#{missing.any? ? 'missing' : 'loaded'}")

      run[:frame_steps] << {
        step_index: idx,
        scroll_percent: pct,
        missing_frame_ids: missing.map { |row| row["id"] },
        frame_state: frame_state,
        screenshot: shot
      }
    end

    action_rows = collect_actions
    run[:action_audit][:total_actions] = action_rows.length
    action_rows.first(MAX_ACTIONS).each_with_index do |action, index|
      run[:action_audit][:results] << test_action(
        action: action,
        index: index,
        viewport_name: viewport[:name],
        profile_path: profile_path
      )
      write_report_snapshot!
    end

    run[:probe] = read_probe_payload
    run
  rescue StandardError => e
    {
      viewport: viewport,
      page: profile_path,
      error: e.message,
      frame_steps: [],
      action_audit: { total_actions: 0, results: [] }
    }
  end

  def wait_for_profile_shell
    Selenium::WebDriver::Wait.new(timeout: WAIT_TIMEOUT).until do
      @driver.current_url.include?("/instagram_profiles/") &&
        @driver.find_elements(css: "h1").any? &&
        @driver.find_elements(css: "turbo-frame[id^='profile_']").any?
    end
  end

  def collect_frame_state
    @driver.execute_script(<<~JS)
      return Array.from(document.querySelectorAll("turbo-frame[id^='profile_']"))
        .map((frame) => {
          const text = String(frame.textContent || "").replace(/\\s+/g, " ").trim();
          const hasLoading = /loading\\s+(captured\\s+posts|downloaded\\s+stories|message\\s+history|action\\s+history|profile\\s+history)/i.test(text);
          const hasContentMissing = /^content missing$/i.test(text);
          const hasContent = text.length > 0 && !hasLoading && !hasContentMissing;
          return {
            id: frame.id || "",
            loaded: hasContent,
            hasLoadingPlaceholder: hasLoading,
            hasContentMissing: hasContentMissing,
            textPreview: text.slice(0, 140),
            childCount: frame.children.length
          };
        });
    JS
  end

  def collect_actions
    raw = @driver.execute_script(<<~JS)
      const root = document.querySelector(".page");
      if (!root) return [];

      return Array.from(root.querySelectorAll("button, a.btn, [role='button']"))
        .filter((el) => {
          if (!(el instanceof HTMLElement)) return false;
          const style = window.getComputedStyle(el);
          const rect = el.getBoundingClientRect();
          const visible = rect.width > 0 && rect.height > 0 && style.visibility !== "hidden" && style.display !== "none";
          const disabled = el.disabled || el.getAttribute("aria-disabled") === "true";
          return visible && !disabled;
        })
        .map((el) => {
          const text = (el.innerText || el.value || el.getAttribute("aria-label") || "").trim().replace(/\\s+/g, " ");
          const href = el.getAttribute("href") || "";
          const dataAction = el.getAttribute("data-action") || "";
          const cls = el.className || "";
          const tag = el.tagName.toLowerCase();
          return {
            tag: tag,
            text: text,
            href: href,
            dataAction: dataAction,
            className: cls,
            fingerprint: [tag, text, href, dataAction, cls].join("|")
          };
        });
    JS

    seen = {}
    raw.each_with_object([]) do |action, rows|
      fp = action["fingerprint"].to_s
      next if fp.empty? || seen[fp]
      seen[fp] = true
      rows << action
    end
  end

  def test_action(action:, index:, viewport_name:, profile_path:)
    visit(profile_path)
    wait_for_profile_shell
    wait_for_profile_frames_loaded(timeout: FRAME_WAIT_TIMEOUT)
    sleep(0.6)

    before = capture_state
    before_path = screenshot("#{viewport_name}_action_#{index}_before")

    click_result = click_action_with_retry(action)
    return action_result(action, click_result[:status], click_result[:detail], before: before, before_screenshot: before_path) if click_result[:status] == "missing"

    sleep(0.8)
    handle_confirmation_modal_if_present
    sleep(0.5)

    after = capture_state
    after_path = screenshot("#{viewport_name}_action_#{index}_after")
    close_extra_windows
    close_open_modals

    action_result(
      action,
      click_result[:status],
      click_result[:detail],
      useful: useful_change?(before, after),
      before: before,
      after: after,
      before_screenshot: before_path,
      after_screenshot: after_path
    )
  rescue StandardError => e
    action_result(action, "error", e.message)
  end

  def click_action_with_retry(action)
    attempts = 0

    begin
      attempts += 1
      el = find_action(action)
      return { status: "missing", detail: "element_not_found" } unless el
      click_element(el)
    rescue Selenium::WebDriver::Error::StaleElementReferenceError => e
      retry if attempts < 2
      { status: "error", detail: e.message }
    end
  end

  def action_result(action, status, detail, useful: nil, before: nil, after: nil, before_screenshot: nil, after_screenshot: nil)
    {
      descriptor: "#{action['tag']} #{action['text']}".strip,
      href: action["href"],
      data_action: action["dataAction"],
      status: status,
      detail: detail,
      useful: useful,
      before: before,
      after: after,
      before_screenshot: before_screenshot,
      after_screenshot: after_screenshot
    }
  end

  def find_action(action)
    candidates = @driver.find_elements(css: ".page button, .page a.btn, .page [role='button']")
    return nil if candidates.empty?

    normalized = ->(value) { value.to_s.strip.gsub(/\s+/, " ") }
    tag = action["tag"].to_s.downcase
    text = normalized.call(action["text"])
    href = action["href"].to_s
    data_action = action["dataAction"].to_s

    by_fingerprint = candidates.find do |el|
      fp = [
        el.tag_name.to_s.downcase,
        normalized.call(el.text),
        el.attribute("href").to_s,
        el.attribute("data-action").to_s,
        el.attribute("class").to_s
      ].join("|")
      fp == action["fingerprint"]
    end
    return by_fingerprint if by_fingerprint

    by_semantic_match = candidates.find do |el|
      next false unless el.tag_name.to_s.downcase == tag
      next false unless normalized.call(el.text) == text

      href_match = href.empty? || el.attribute("href").to_s == href
      data_action_match = data_action.empty? || el.attribute("data-action").to_s == data_action
      href_match && data_action_match
    end
    return by_semantic_match if by_semantic_match

    candidates.find do |el|
      next false unless el.tag_name.to_s.downcase == tag
      normalized.call(el.text) == text
    end
  end

  def click_element(element)
    @driver.execute_script("arguments[0].scrollIntoView({ block: 'center', inline: 'nearest' });", element)
    sleep(0.2)
    element.click
    { status: "clicked", detail: nil }
  rescue Selenium::WebDriver::Error::ElementClickInterceptedError
    @driver.execute_script("arguments[0].click();", element)
    { status: "clicked_js", detail: "intercepted" }
  rescue Selenium::WebDriver::Error::UnexpectedAlertOpenError
    @driver.switch_to.alert.accept rescue nil
    { status: "clicked_alert", detail: "alert_accepted" }
  end

  def handle_confirmation_modal_if_present
    confirm = @driver.find_elements(css: "#confirmAction").first
    return unless confirm

    confirm.click
  rescue StandardError
    nil
  end

  def close_open_modals
    # Bootstrap modal fallback close actions.
    @driver.find_elements(css: ".modal.show [data-bs-dismiss='modal'], .modal.show .btn-close").each do |el|
      begin
        el.click
      rescue StandardError
        nil
      end
    end

    # Native dialog close buttons.
    @driver.find_elements(css: "dialog[open] button").each do |el|
      begin
        next unless el.text.to_s.strip.downcase.include?("close")
        el.click
      rescue StandardError
        nil
      end
    end

    # Overlay modals.
    @driver.find_elements(css: ".story-modal-overlay [data-modal-close='story']").each do |el|
      begin
        el.click
      rescue StandardError
        nil
      end
    end
  rescue StandardError
    nil
  end

  def close_extra_windows
    handles = @driver.window_handles
    return if handles.size <= 1

    handles[1..].each do |handle|
      @driver.switch_to.window(handle)
      @driver.close
    end
    @driver.switch_to.window(handles.first)
  rescue StandardError
    nil
  end

  def capture_state
    {
      url: @driver.current_url,
      title: @driver.title,
      window_count: @driver.window_handles.length,
      notifications: @driver.find_elements(css: "#notifications .notification").map { |el| el.text.to_s.strip }.reject(&:empty?).last(6),
      open_dialogs: @driver.find_elements(css: "dialog[open]").length,
      open_bootstrap_modals: @driver.find_elements(css: ".modal.show").length,
      missing_frames: collect_frame_state.select { |row| !row["loaded"] }.map { |row| row["id"] }
    }
  rescue StandardError
    {}
  end

  def useful_change?(before, after)
    before[:url] != after[:url] ||
      before[:window_count] != after[:window_count] ||
      before[:notifications] != after[:notifications] ||
      before[:open_dialogs] != after[:open_dialogs] ||
      before[:open_bootstrap_modals] != after[:open_bootstrap_modals] ||
      before[:missing_frames] != after[:missing_frames]
  end

  def read_probe_payload
    @driver.execute_script("return window.__profileAudit || null;")
  rescue StandardError
    nil
  end

  def visit(path)
    @driver.navigate.to(URI.join(@base_url, path).to_s)
    wait_for_ready_state
  end

  def wait_for_ready_state
    Selenium::WebDriver::Wait.new(timeout: WAIT_TIMEOUT).until do
      @driver.execute_script("return document.readyState") == "complete"
    end
  end

  def wait_for_profile_frames_loaded(timeout:)
    Selenium::WebDriver::Wait.new(timeout: timeout).until do
      rows = collect_frame_state
      rows.any? && rows.all? { |row| row["loaded"] }
    end
  rescue Selenium::WebDriver::Error::TimeoutError
    nil
  end

  def screenshot(name)
    filename = name.to_s.gsub(/[^a-zA-Z0-9_-]+/, "_")
    path = File.join(@output_dir, "#{filename}.png")
    @driver.save_screenshot(path)
    path
  end

  def write_report!
    path = File.join(@output_dir, "report.json")
    File.write(path, JSON.pretty_generate(@report))
    puts "Profile page UI audit complete."
    puts "Screenshots/report: #{@output_dir}"
  end

  def write_report_snapshot!
    path = File.join(@output_dir, "report.json")
    File.write(path, JSON.pretty_generate(@report))
  rescue StandardError
    nil
  end
end

if __FILE__ == $PROGRAM_NAME
  ProfilePageUiAudit.new.run
end
