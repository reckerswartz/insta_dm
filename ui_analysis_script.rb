#!/usr/bin/env ruby

require "digest"
require "fileutils"
require "json"
require "net/http"
require "selenium-webdriver"
require "set"
require "time"
require "timeout"
require "uri"

class UIClickAudit
  CLICKABLE_SELECTOR = "button, input[type='button'], input[type='submit']"
  INTERNAL_LINK_SELECTOR = "a[href]"

  DEFAULT_BASE_URL = "http://127.0.0.1:3000"
  DEFAULT_PAGE_LIMIT = 20
  DEFAULT_MAX_ELEMENTS_PER_PAGE = 80
  DEFAULT_VIEWPORT = "1600,1000"
  DEFAULT_WAIT_MS = 450
  SKIP_PATH_PATTERNS = [
    %r{\A/admin/jobs},
  ].freeze
  DYNAMIC_PATH_LIMITS = {
    %r{\A/instagram_accounts/\d+\z} => 2,
    %r{\A/instagram_posts/\d+\z} => 3,
    %r{\A/instagram_profiles/\d+\z} => 4,
    %r{\A/admin/background_jobs/failures/\d+\z} => 3,
  }.freeze

  def initialize
    @base_url = ENV.fetch("UI_BASE_URL", DEFAULT_BASE_URL)
    @page_limit = ENV.fetch("UI_PAGE_LIMIT", DEFAULT_PAGE_LIMIT).to_i
    @max_elements_per_page = ENV.fetch("UI_MAX_ELEMENTS_PER_PAGE", DEFAULT_MAX_ELEMENTS_PER_PAGE).to_i
    @wait_after_click = ENV.fetch("UI_WAIT_MS", DEFAULT_WAIT_MS).to_i / 1000.0
    @viewport = ENV.fetch("UI_VIEWPORT", DEFAULT_VIEWPORT)
    @parsed_base = URI.parse(@base_url)

    timestamp = Time.now.utc.strftime("%Y%m%d_%H%M%S")
    viewport_token = @viewport.tr(",", "x")
    @screenshots_dir = File.join(Dir.pwd, "tmp", "ui_click_audit", "#{timestamp}_#{viewport_token}")
    FileUtils.mkdir_p(@screenshots_dir)

    @pages = []
    @results = []

    chrome_options = Selenium::WebDriver::Chrome::Options.new
    chrome_options.add_argument("--headless=new")
    chrome_options.add_argument("--window-size=#{@viewport}")
    chrome_options.add_argument("--disable-gpu")
    chrome_options.add_argument("--no-sandbox")
    chrome_options.add_argument("--disable-dev-shm-usage")
    chrome_options.add_argument("--disable-infobars")
    chrome_options.add_option("goog:loggingPrefs", { browser: "ALL" })

    @driver = Selenium::WebDriver.for(:chrome, options: chrome_options)
    @driver.manage.timeouts.page_load = 22
    @driver.manage.timeouts.script_timeout = 10
    @browser_logs_supported = true
  end

  def run
    abort_unless_server_online!

    puts "UI click audit started"
    puts "Base URL: #{@base_url}"
    puts "Viewport: #{@viewport}"
    puts "Screenshot directory: #{@screenshots_dir}"

    discover_pages!
    puts "Pages queued (#{@pages.length}):"
    @pages.each { |page| puts "  - #{page}" }

    @pages.each_with_index do |path, idx|
      analyze_page(path, idx + 1)
    end

    write_report!
  ensure
    @driver&.quit
  end

  private

  def abort_unless_server_online!
    uri = URI.join(@base_url, "/up")
    response = Net::HTTP.get_response(uri)
    return if response.code.to_i == 200

    raise "Server health endpoint returned #{response.code}"
  rescue StandardError => e
    raise "Cannot connect to #{@base_url}: #{e.message}"
  end

  def discover_pages!
    queue = ["/"]
    seen = Set.new
    ordered = []
    planned_dynamic_counts = Hash.new(0)

    while queue.any? && seen.length < @page_limit
      path = queue.shift
      next if seen.include?(path)

      seen << path
      ordered << path

      begin
        visit(path)
        collect_internal_links.each do |candidate|
          next unless enqueue_allowed?(candidate, seen, queue, planned_dynamic_counts)
          queue << candidate
        end
      rescue StandardError => e
        puts "Discovery warning for #{path}: #{e.message}"
      end
    end

    @pages = ordered
  end

  def enqueue_allowed?(candidate, seen, queue, planned_dynamic_counts)
    return false if seen.include?(candidate)
    return false if queue.include?(candidate)
    return false if queue.length + seen.length >= @page_limit

    limit_pair = dynamic_limit_pair(candidate)
    return true unless limit_pair

    pattern, limit = limit_pair
    return false if planned_dynamic_counts[pattern] >= limit

    planned_dynamic_counts[pattern] += 1
    true
  end

  def dynamic_limit_pair(path)
    DYNAMIC_PATH_LIMITS.find { |pattern, _limit| path.match?(pattern) }
  end

  def collect_internal_links
    hrefs = Array(@driver.find_elements(css: INTERNAL_LINK_SELECTOR)).map { |link| link.attribute("href") }.compact
    hrefs.filter_map { |href| normalize_internal_path(href) }.uniq
  rescue StandardError
    []
  end

  def normalize_internal_path(href)
    uri = URI.parse(href)
    return if uri.scheme && !%w[http https].include?(uri.scheme)
    return if uri.host && uri.host != @parsed_base.host
    return if uri.path.start_with?("/rails/active_storage")
    return if uri.path.start_with?("/assets")
    return if uri.path.start_with?("/packs")
    return if uri.path.start_with?("/cable")
    return if SKIP_PATH_PATTERNS.any? { |pattern| uri.path.match?(pattern) }

    path = uri.path.to_s.strip
    path = "/" if path.empty?

    query = uri.query.to_s
    return path if query.empty?

    "#{path}?#{query}"
  rescue URI::InvalidURIError
    nil
  end

  def analyze_page(path, index)
    puts "\n[#{index}/#{@pages.length}] Analyzing #{path}"
    visit(path)

    baseline = screenshot("#{safe_name(path)}_baseline")
    elements = collect_clickable_elements

    puts "  Found #{elements.length} clickable elements"

    page_result = {
      page: path,
      title: @driver.title,
      baseline_screenshot: baseline,
      browser_logs: drain_browser_logs(context: "#{path}:initial"),
      tested: [],
    }

    elements.each_with_index do |probe, element_index|
      page_result[:tested] << test_element(path, probe, element_index)
      page_result[:browser_logs].concat(drain_browser_logs(context: "#{path}:after_click_#{element_index + 1}"))
    end

    page_result[:browser_logs].concat(drain_browser_logs(context: "#{path}:complete"))

    @results << page_result
  rescue StandardError => e
    @results << {
      page: path,
      title: nil,
      baseline_screenshot: nil,
      error: e.message,
      browser_logs: drain_browser_logs(context: "#{path}:error"),
      tested: [],
    }
  end

  def collect_clickable_elements
    raw = @driver.execute_script(<<~JS, CLICKABLE_SELECTOR, @max_elements_per_page)
      const selector = arguments[0];
      const maxElements = arguments[1];
      const rows = [];
      const els = Array.from(document.querySelectorAll(selector));

      for (const el of els) {
        if (rows.length >= maxElements) break;

        const rect = el.getBoundingClientRect();
        const style = window.getComputedStyle(el);
        const visible = rect.width > 0 && rect.height > 0 && style.display !== "none" && style.visibility !== "hidden";
        if (!visible || el.disabled) continue;

        const text = (el.innerText || el.value || el.getAttribute("aria-label") || "").trim().replace(/\\s+/g, " ");
        const href = el.getAttribute("href") || "";
        const type = el.getAttribute("type") || "";
        const dataAction = el.getAttribute("data-action") || "";
        const cls = el.className || "";
        const role = el.getAttribute("role") || "";
        const semanticClass = cls.toString().split(/\\s+/).filter(Boolean).sort().join(".");

        const fingerprint = [
          el.tagName.toUpperCase(),
          text,
          el.id || "",
          href,
          el.getAttribute("name") || "",
          dataAction,
          type,
          role,
          cls
        ].join("|");

        const semanticKey = [
          el.tagName.toUpperCase(),
          text,
          type,
          role,
          dataAction,
          semanticClass
        ].join("|");

        rows.push({
          tag: el.tagName.toLowerCase(),
          text,
          id: el.id || "",
          href,
          type,
          role,
          className: cls,
          dataAction,
          fingerprint,
          semanticKey
        });
      }

      return rows;
    JS

    uniq = {}
    raw.each do |row|
      key = row["semanticKey"].to_s.strip
      next if key.empty?
      uniq[key] ||= row
    end

    uniq.values
  end

  def test_element(path, probe, index)
    descriptor = "#{probe['tag']} '#{probe['text']}'".strip
    puts "  -> [#{index + 1}] #{descriptor}"

    Timeout.timeout(24) do
      visit(path)
      target = find_element_again(probe)
      return result_for_missing(probe, descriptor) unless target

      before_state = capture_state
      before_shot = screenshot("#{safe_name(path)}_#{index}_before")

      click_result = click_element(target)
      sleep @wait_after_click

      handle_extra_windows!
      alert_text = accept_alert_if_present
      dismiss_confirm_if_present

      after_state = capture_state
      after_shot = screenshot("#{safe_name(path)}_#{index}_after")

      useful = useful_action?(before_state, after_state, click_result, alert_text)
      worked = click_result[:status].start_with?("clicked")

      {
        descriptor: descriptor,
        fingerprint: probe["fingerprint"],
        status: click_result[:status],
        detail: click_result[:detail],
        worked: worked,
        useful: useful,
        before: before_state,
        after: after_state,
        before_screenshot: before_shot,
        after_screenshot: after_shot,
      }
    end
  rescue Timeout::Error
    {
      descriptor: descriptor,
      fingerprint: probe["fingerprint"],
      status: "timeout",
      detail: "action_timed_out",
      worked: false,
      useful: false,
    }
  rescue StandardError => e
    {
      descriptor: descriptor,
      fingerprint: probe["fingerprint"],
      status: "error",
      detail: e.message,
      worked: false,
      useful: false,
    }
  end

  def result_for_missing(probe, descriptor)
    {
      descriptor: descriptor,
      fingerprint: probe["fingerprint"],
      status: "missing",
      detail: "element_not_found_on_reload",
      worked: false,
      useful: false,
    }
  end

  def click_element(target)
    @driver.execute_script("arguments[0].scrollIntoView({block: 'center', inline: 'nearest'});", target)
    sleep 0.18

    begin
      target.click
      { status: "clicked", detail: nil }
    rescue Selenium::WebDriver::Error::ElementClickInterceptedError
      @driver.execute_script("arguments[0].click();", target)
      { status: "clicked_js", detail: "click_intercepted" }
    rescue Selenium::WebDriver::Error::ElementNotInteractableError
      @driver.execute_script("arguments[0].click();", target)
      { status: "clicked_js", detail: "not_interactable" }
    rescue Selenium::WebDriver::Error::UnexpectedAlertOpenError
      { status: "clicked_alert", detail: "unexpected_alert_open" }
    end
  end

  def accept_alert_if_present
    alert = @driver.switch_to.alert
    text = alert.text.to_s
    alert.accept
    text
  rescue Selenium::WebDriver::Error::NoSuchAlertError
    nil
  end

  def dismiss_confirm_if_present
    cancel_btn = @driver.find_elements(css: ".modal.show [data-bs-dismiss='modal'], .modal.show .btn-close").first
    cancel_btn&.click
  rescue StandardError
    nil
  end

  def find_element_again(probe)
    candidates = Array(@driver.find_elements(css: CLICKABLE_SELECTOR))
    candidates.find do |el|
      next false if !el.displayed? || !el.enabled?

      text = (el.text.strip.empty? ? (el.attribute("value") || el.attribute("aria-label") || "") : el.text).to_s.strip.gsub(/\s+/, " ")
      fingerprint = [
        el.tag_name.to_s.upcase,
        text,
        el.attribute("id").to_s,
        el.attribute("href").to_s,
        el.attribute("name").to_s,
        el.attribute("data-action").to_s,
        el.attribute("type").to_s,
        el.attribute("role").to_s,
        el.attribute("class").to_s,
      ].join("|")

      fingerprint == probe["fingerprint"]
    rescue Selenium::WebDriver::Error::StaleElementReferenceError
      false
    end
  end

  def capture_state
    text_sample = @driver.execute_script("return (document.body && document.body.innerText || '').slice(0, 6000);")
    notifications = Array(@driver.find_elements(css: ".alert, .notification, [role='alert']"))
                           .map { |el| el.text.to_s.strip }
                           .reject(&:empty?)

    {
      url: @driver.current_url,
      title: @driver.title,
      modal_count: Array(@driver.find_elements(css: ".modal.show, dialog[open]")).size,
      notifications: notifications.uniq,
      body_hash: Digest::MD5.hexdigest(text_sample),
    }
  end

  def useful_action?(before_state, after_state, click_result, alert_text)
    return true if alert_text.to_s.strip.length.positive?
    return false unless click_result[:status].start_with?("clicked")

    before_state[:url] != after_state[:url] ||
      before_state[:modal_count] != after_state[:modal_count] ||
      before_state[:notifications] != after_state[:notifications] ||
      before_state[:body_hash] != after_state[:body_hash]
  end

  def handle_extra_windows!
    handles = Array(@driver.window_handles)
    return if handles.size <= 1

    handles[1..].each do |handle|
      @driver.switch_to.window(handle)
      @driver.close
    end

    @driver.switch_to.window(handles.first)
  end

  def visit(path)
    @driver.navigate.to(URI.join(@base_url, path).to_s)
    sleep 1.0
  end

  def screenshot(name)
    file = File.join(@screenshots_dir, "#{safe_name(name)}.png")
    @driver.save_screenshot(file)
    file
  end

  def safe_name(value)
    value.to_s.gsub(/[^a-zA-Z0-9_-]+/, "_").gsub(/_+/, "_").sub(/^_/, "").sub(/_$/, "")
  end

  def write_report!
    flattened = @results.flat_map { |row| row[:tested] || [] }
    browser_logs = @results.flat_map { |row| row[:browser_logs] || [] }
    worked_count = flattened.count { |item| item[:worked] }
    useful_count = flattened.count { |item| item[:useful] }
    errors_count = flattened.count { |item| %w[error timeout].include?(item[:status]) }
    missing_count = flattened.count { |item| item[:status] == "missing" }
    browser_error_count = browser_logs.count { |entry| severe_browser_log?(entry) }

    report = {
      generated_at: Time.now.utc.iso8601,
      base_url: @base_url,
      viewport: @viewport,
      screenshot_directory: @screenshots_dir,
      page_limit: @page_limit,
      max_elements_per_page: @max_elements_per_page,
      pages: @results,
      summary: {
        pages_tested: @results.length,
        total_click_targets: flattened.length,
        worked_actions: worked_count,
        useful_actions: useful_count,
        errors: errors_count,
        missing_after_reload: missing_count,
        browser_log_entries: browser_logs.length,
        browser_log_errors: browser_error_count,
      },
    }

    report_path = File.join(@screenshots_dir, "ui_click_audit_report.json")
    File.write(report_path, JSON.pretty_generate(report))

    puts "\nUI click audit complete"
    puts "Report: #{report_path}"
    puts "Summary: #{report[:summary]}"
  end

  def drain_browser_logs(context:)
    return [] unless @browser_logs_supported

    entries =
      if @driver.respond_to?(:logs)
        Array(@driver.logs.get(:browser))
      elsif @driver.manage.respond_to?(:logs)
        Array(@driver.manage.logs.get(:browser))
      else
        []
      end

    entries.map do |entry|
      {
        context: context,
        level: entry.level.to_s,
        timestamp: Time.at(entry.timestamp.to_f / 1000.0).utc.iso8601,
        message: entry.message.to_s,
      }
    end
  rescue Selenium::WebDriver::Error::UnknownError, Selenium::WebDriver::Error::UnsupportedOperationError, NoMethodError
    @browser_logs_supported = false
    []
  end

  def severe_browser_log?(entry)
    level = entry[:level].to_s.upcase
    message = entry[:message].to_s

    return true if level == "SEVERE"
    return true if message.match?(/ChunkLoadError|Failed to load resource|Uncaught/i)

    false
  end
end

if __FILE__ == $PROGRAM_NAME
  UIClickAudit.new.run
end
