#!/usr/bin/env ruby

require "fileutils"
require "json"
require "net/http"
require "selenium-webdriver"
require "time"
require "uri"

STDOUT.sync = true

class StoryArchiveUiAudit
  VIEWPORTS = [
    { name: "desktop", width: 1600, height: 1000 },
    { name: "tablet", width: 1100, height: 900 }
  ].freeze

  MAX_ACTIONS = ENV.fetch("STORY_UI_AUDIT_MAX_ACTIONS", "60").to_i.clamp(1, 250)

  def initialize
    @base_url = ENV.fetch("UI_BASE_URL", "http://127.0.0.1:3000")
    timestamp = Time.now.utc.strftime("%Y%m%d_%H%M%S")
    @output_dir = File.join(Dir.pwd, "tmp", "story_archive_ui_audit", timestamp)
    FileUtils.mkdir_p(@output_dir)
    @report = {
      generated_at: Time.now.utc.iso8601,
      base_url: @base_url,
      output_dir: @output_dir,
      runs: []
    }

    @driver = Selenium::WebDriver.for(:chrome, options: build_options)
    @driver.manage.timeouts.page_load = 20
    @driver.manage.timeouts.script_timeout = 12
  end

  def run
    ensure_server_online!
    account_path = discover_account_path
    raise "Could not find an account page from dashboard links." if account_path.to_s.empty?

    puts "Story archive UI audit started for #{account_path}"
    puts "Output directory: #{@output_dir}"

    VIEWPORTS.each do |viewport|
      puts "Running viewport #{viewport[:name]} (#{viewport[:width]}x#{viewport[:height]})..."
      @driver.manage.window.resize_to(viewport[:width], viewport[:height])
      @report[:runs] << run_for_viewport(account_path: account_path, viewport: viewport)
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

  def discover_account_path
    visit("/")
    sleep(0.8)

    href = @driver.find_elements(tag_name: "a")
                  .map { |el| el.attribute("href") }
                  .compact
                  .find { |value| URI(value).path.match?(%r{^/instagram_accounts/\d+$}) rescue false }

    href ? URI(href).path : nil
  end

  def run_for_viewport(account_path:, viewport:)
    visit(account_path)
    wait_for_story_archive_ready

    run = {
      viewport: viewport,
      page: account_path,
      baseline: screenshot("#{viewport[:name]}_baseline"),
      actions: []
    }

    scroll_archive_container(viewport[:name], run)

    actions = collect_actions.first(MAX_ACTIONS)
    puts "  Collected #{actions.length} interactive actions"
    actions.each_with_index do |action, index|
      puts "    [#{index + 1}/#{actions.length}] #{action['tag']} #{action['text']}".strip
      run[:actions] << test_action(action: action, index: index, viewport_name: viewport[:name], page: account_path)
      write_report_snapshot!
    end

    run
  rescue StandardError => e
    {
      viewport: viewport,
      page: account_path,
      error: e.message,
      actions: []
    }
  end

  def wait_for_story_archive_ready
    Selenium::WebDriver::Wait.new(timeout: 20).until do
      cards = @driver.find_elements(css: ".story-media-card")
      empty_state = @driver.find_elements(css: "[data-story-media-archive-target='empty']:not([hidden])")
      cards.any? || empty_state.any?
    end
  end

  def scroll_archive_container(prefix, run)
    holder = @driver.find_elements(css: "[data-story-media-archive-target='scroll']").first
    return unless holder

    @driver.execute_script("arguments[0].scrollTop = Math.max(arguments[0].scrollHeight * 0.45, 320);", holder)
    sleep(0.35)
    @driver.execute_script("arguments[0].scrollLeft = Math.max(arguments[0].scrollWidth * 0.35, 140);", holder)
    sleep(0.35)
    run[:scroll_check] = screenshot("#{prefix}_scroll_probe")
  rescue StandardError => e
    run[:scroll_error] = e.message
  end

  def collect_actions
    raw = @driver.execute_script(<<~JS)
      const section = document.querySelector("[data-controller~='story-media-archive']");
      if (!section) return [];

      return Array.from(section.querySelectorAll("button, a.btn"))
        .filter((el) => {
          const rect = el.getBoundingClientRect();
          const visible = rect.width > 0 && rect.height > 0;
          return visible && !el.disabled;
        })
        .map((el) => {
          const text = (el.innerText || el.value || el.getAttribute("aria-label") || "").trim().replace(/\\s+/g, " ");
          return {
            text: text,
            tag: el.tagName.toLowerCase(),
            href: el.getAttribute("href") || "",
            eventId: el.getAttribute("data-event-id") || "",
            dataAction: el.getAttribute("data-action") || "",
            className: el.className || "",
            fingerprint: [el.tagName, text, el.getAttribute("data-event-id") || "", el.getAttribute("data-action") || "", el.className || ""].join("|")
          };
        });
    JS

    seen = {}
    raw.each_with_object([]) do |action, rows|
      next if action["fingerprint"].to_s.empty?
      next if seen[action["fingerprint"]]
      seen[action["fingerprint"]] = true
      rows << action
    end
  end

  def test_action(action:, index:, viewport_name:, page:)
    visit(page)
    wait_for_story_archive_ready

    element = find_action(action)
    return action_result(action, "missing", "element_not_found") unless element

    before = capture_state
    before_path = screenshot("#{viewport_name}_#{index}_before")

    click_status = click_element(element)
    sleep(0.7)
    observed = capture_state
    observed_path = screenshot("#{viewport_name}_#{index}_observed")
    close_extra_windows
    close_modals_if_open

    after = capture_state
    after_path = screenshot("#{viewport_name}_#{index}_after")

    action_result(
      action,
      click_status[:status],
      click_status[:detail],
      before: before,
      after: observed,
      useful: useful_change?(before, observed),
      before_screenshot: before_path,
      after_screenshot: observed_path,
      cleanup_screenshot: after_path
    )
  rescue StandardError => e
    action_result(action, "error", e.message)
  end

  def action_result(action, status, detail, before: nil, after: nil, useful: nil, before_screenshot: nil, after_screenshot: nil, cleanup_screenshot: nil)
    {
      descriptor: "#{action['tag']} #{action['text']}".strip,
      data_action: action["dataAction"],
      event_id: action["eventId"],
      status: status,
      detail: detail,
      useful: useful,
      before: before,
      after: after,
      before_screenshot: before_screenshot,
      after_screenshot: after_screenshot,
      cleanup_screenshot: cleanup_screenshot
    }
  end

  def find_action(action)
    @driver.find_elements(css: "[data-controller~='story-media-archive'] button, [data-controller~='story-media-archive'] a.btn").find do |el|
      text = el.text.to_s.strip.gsub(/\s+/, " ")
      fp = [
        el.tag_name.to_s.upcase,
        text,
        el.attribute("data-event-id").to_s,
        el.attribute("data-action").to_s,
        el.attribute("class").to_s
      ].join("|")
      fp == action["fingerprint"]
    end
  end

  def click_element(element)
    @driver.execute_script("arguments[0].scrollIntoView({ block: 'center', inline: 'nearest' });", element)
    sleep(0.2)
    element.click
    { status: "clicked", detail: nil }
  rescue Selenium::WebDriver::Error::ElementClickInterceptedError
    @driver.execute_script("arguments[0].click();", element)
    { status: "clicked_js", detail: "click_intercepted" }
  rescue Selenium::WebDriver::Error::UnexpectedAlertOpenError
    @driver.switch_to.alert.accept rescue nil
    { status: "clicked_alert", detail: "alert_accepted" }
  end

  def close_extra_windows
    handles = @driver.window_handles
    return if handles.size <= 1

    handles[1..].each do |handle|
      @driver.switch_to.window(handle)
      @driver.close
    end
    @driver.switch_to.window(handles.first)
  end

  def close_modals_if_open
    story_close = @driver.find_elements(css: ".story-modal-overlay [data-modal-close='story']").first
    if story_close
      story_close.click
      sleep(0.2)
    end

    tech_close = @driver.find_elements(css: ".technical-details-modal:not(.hidden) [data-action*='technical-details#hideModal']").first
    if tech_close
      tech_close.click
      sleep(0.2)
    end
  rescue StandardError
    nil
  end

  def capture_state
    {
      url: @driver.current_url,
      title: @driver.title,
      story_modal_open: @driver.find_elements(css: ".story-modal-overlay").any?,
      technical_modal_open: @driver.find_elements(css: ".technical-details-modal:not(.hidden)").any?,
      notifications: @driver.find_elements(css: "#notifications .notification").map { |el| el.text.to_s.strip }.reject(&:empty?).last(5)
    }
  end

  def useful_change?(before, after)
    before[:url] != after[:url] ||
      before[:story_modal_open] != after[:story_modal_open] ||
      before[:technical_modal_open] != after[:technical_modal_open] ||
      before[:notifications] != after[:notifications]
  end

  def visit(path)
    @driver.navigate.to(URI.join(@base_url, path).to_s)
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

    puts "Story archive UI audit complete."
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
  StoryArchiveUiAudit.new.run
end
