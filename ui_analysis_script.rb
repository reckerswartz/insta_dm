#!/usr/bin/env ruby

require "digest"
require "fileutils"
require "json"
require "net/http"
require "selenium-webdriver"
require "time"
require "timeout"
require "uri"

class UIAnalyzer
  INTERACTIVE_SELECTOR = "button, input[type='button'], input[type='submit'], a.btn, [role='button']"
  MAX_ELEMENTS_PER_PAGE = 36
  SKIP_PATTERNS = [
    /delete/i,
    /clear queue/i,
    /stop all jobs/i,
    /danger zone/i,
    /remove/i,
    /manual browser login/i,
    /download/i,
    /export/i,
    /open on instagram/i,
    /mission control/i,
    /run all tests/i
  ]

  def initialize
    @base_url = ENV.fetch("UI_BASE_URL", "http://127.0.0.1:3000")
    timestamp = Time.now.utc.strftime("%Y%m%d_%H%M%S")
    @screenshots_dir = File.join(Dir.pwd, "tmp", "ui_screenshots", timestamp)
    FileUtils.mkdir_p(@screenshots_dir)

    @pages = []
    @results = []

    chrome_options = Selenium::WebDriver::Chrome::Options.new
    chrome_options.add_argument("--headless=new")
    chrome_options.add_argument("--window-size=1600,1000")
    chrome_options.add_argument("--disable-gpu")
    chrome_options.add_argument("--no-sandbox")
    chrome_options.add_argument("--disable-dev-shm-usage")

    @driver = Selenium::WebDriver.for(:chrome, options: chrome_options)
    @driver.manage.timeouts.page_load = 12
    @driver.manage.timeouts.script_timeout = 8
  end

  def run
    abort_unless_server_online!

    puts "UI analyzer started"
    puts "Base URL: #{@base_url}"
    puts "Screenshot directory: #{@screenshots_dir}"

    build_page_list!

    @pages.each do |page|
      analyze_page(page)
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

  def build_page_list!
    static_pages = [
      { name: "dashboard", path: "/" },
      { name: "profiles", path: "/instagram_profiles" },
      { name: "posts", path: "/instagram_posts" },
      { name: "ai_dashboard", path: "/ai_dashboard" },
      { name: "jobs", path: "/admin/background_jobs" },
      { name: "job_failures", path: "/admin/background_jobs/failures" }
    ]

    @pages = static_pages.dup

    discover_dynamic_page!("dashboard", /\/instagram_accounts\/\d+$/)
    discover_dynamic_page!("profiles", /\/instagram_profiles\/\d+$/)
    discover_dynamic_page!("posts", /\/instagram_posts\/\d+$/)
    discover_dynamic_page!("job_failures", /\/admin\/background_jobs\/failures\/\d+$/)

    @pages.uniq! { |p| p[:path] }

    puts "Pages queued:"
    @pages.each { |page| puts "  - #{page[:path]}" }
  end

  def discover_dynamic_page!(source_name, path_pattern)
    source_page = @pages.find { |p| p[:name] == source_name }
    return unless source_page

    visit(source_page[:path])
    sleep 1.2

    hrefs = @driver.find_elements(tag_name: "a").map { |link| link.attribute("href") }.compact
    match = hrefs.find { |href| URI(href).path.match?(path_pattern) rescue false }
    return unless match

    path = URI(match).path
    @pages << { name: "dynamic_#{source_name}", path: path }
  rescue StandardError => e
    puts "Dynamic discovery skipped for #{source_name}: #{e.message}"
  end

  def analyze_page(page)
    puts "\nAnalyzing #{page[:path]}"
    visit(page[:path])

    baseline_path = screenshot("#{page[:name]}_baseline")
    elements = collect_interactive_elements.first(MAX_ELEMENTS_PER_PAGE)

    puts "  Found #{elements.size} interactive elements (cap #{MAX_ELEMENTS_PER_PAGE})"

    page_result = {
      page: page[:path],
      title: @driver.title,
      baseline_screenshot: baseline_path,
      tested: []
    }

    elements.each_with_index do |element, index|
      page_result[:tested] << test_element(page, element, index)
    end

    @results << page_result
  rescue StandardError => e
    @results << {
      page: page[:path],
      title: nil,
      baseline_screenshot: nil,
      error: e.message,
      tested: []
    }
  end

  def collect_interactive_elements
    raw = @driver.execute_script(<<~JS, INTERACTIVE_SELECTOR)
      return Array.from(document.querySelectorAll(arguments[0])).map((el) => {
        const rect = el.getBoundingClientRect();
        const style = window.getComputedStyle(el);
        const visible = rect.width > 0 && rect.height > 0 && style.display !== "none" && style.visibility !== "hidden";
        if (!visible) return null;

        const text = (el.innerText || el.value || el.getAttribute("aria-label") || "").trim().replace(/\s+/g, " ");
        return {
          tag: el.tagName.toLowerCase(),
          id: el.id || "",
          className: el.className || "",
          type: el.getAttribute("type") || "",
          href: el.getAttribute("href") || "",
          name: el.getAttribute("name") || "",
          text: text,
          disabled: !!el.disabled,
          dataAction: el.getAttribute("data-action") || "",
          fingerprint: [el.tagName, text, el.id, el.getAttribute("href") || "", el.getAttribute("name") || "", el.getAttribute("data-action") || ""].join("|")
        }
      }).filter(Boolean)
    JS

    uniq = {}
    raw.each do |item|
      next if item["disabled"]
      next if item["fingerprint"].to_s.strip.empty?
      uniq[item["fingerprint"]] ||= item
    end

    uniq.values
  end

  def test_element(page, element, index)
    descriptor = "#{element['tag']} '#{element['text']}'"
    puts "  -> Testing #{descriptor}"

    if destructive?(element)
      return {
        descriptor: descriptor,
        status: "skipped",
        reason: "destructive_action"
      }
    end

    Timeout.timeout(18) do
      visit(page[:path])
      target = find_element_again(element)

      return {
        descriptor: descriptor,
        status: "missing",
        reason: "element_not_found_on_reload"
      } unless target

      before_state = capture_state
      before_path = screenshot("#{safe_name(page[:name])}_#{index}_before")

      click_result = click_element(target)
      sleep 1

      handle_extra_windows!
      dismiss_modal_if_needed

      after_state = capture_state
      after_path = screenshot("#{safe_name(page[:name])}_#{index}_after")

      useful = state_changed?(before_state, after_state)

      {
        descriptor: descriptor,
        status: click_result[:status],
        detail: click_result[:detail],
        useful: useful,
        before: before_state,
        after: after_state,
        before_screenshot: before_path,
        after_screenshot: after_path
      }
    end
  rescue Timeout::Error
    {
      descriptor: descriptor,
      status: "timeout",
      detail: "action_timed_out"
    }
  rescue StandardError => e
    {
      descriptor: descriptor,
      status: "error",
      detail: e.message
    }
  end

  def click_element(element)
    @driver.execute_script("arguments[0].scrollIntoView({block: 'center'});", element)
    sleep 0.2

    begin
      element.click
      accept_alert_if_present
      { status: "clicked", detail: nil }
    rescue Selenium::WebDriver::Error::ElementClickInterceptedError
      @driver.execute_script("arguments[0].click();", element)
      accept_alert_if_present
      { status: "clicked_js", detail: "click_intercepted" }
    rescue Selenium::WebDriver::Error::UnexpectedAlertOpenError
      accept_alert_if_present
      { status: "clicked_alert", detail: "alert_accepted" }
    end
  end

  def accept_alert_if_present
    @driver.switch_to.alert.accept
  rescue Selenium::WebDriver::Error::NoSuchAlertError
    nil
  end

  def find_element_again(probe)
    candidates = @driver.find_elements(css: INTERACTIVE_SELECTOR)

    candidates.find do |el|
      text = (el.text.strip.empty? ? (el.attribute("value") || el.attribute("aria-label") || "") : el.text).to_s.strip.gsub(/\s+/, " ")
      fingerprint = [
        el.tag_name.to_s.upcase,
        text,
        el.attribute("id").to_s,
        el.attribute("href").to_s,
        el.attribute("name").to_s,
        el.attribute("data-action").to_s
      ].join("|")

      fingerprint == probe["fingerprint"]
    end
  end

  def destructive?(element)
    haystack = [element["text"], element["className"], element["href"], element["dataAction"]].join(" ")
    SKIP_PATTERNS.any? { |pattern| haystack.match?(pattern) }
  end

  def capture_state
    text_sample = @driver.execute_script("return (document.body && document.body.innerText || '').slice(0, 3000);")
    notifications = @driver.find_elements(css: ".alert, .notification, [role='alert']").map { |el| el.text.strip }.reject(&:empty?)

    {
      url: @driver.current_url,
      title: @driver.title,
      modal_count: @driver.find_elements(css: ".modal.show, dialog[open]").size,
      notifications: notifications.uniq,
      body_hash: Digest::MD5.hexdigest(text_sample)
    }
  end

  def state_changed?(before_state, after_state)
    before_state[:url] != after_state[:url] ||
      before_state[:modal_count] != after_state[:modal_count] ||
      before_state[:notifications] != after_state[:notifications] ||
      before_state[:body_hash] != after_state[:body_hash]
  end

  def dismiss_modal_if_needed
    close_buttons = @driver.find_elements(css: ".modal.show [data-bs-dismiss='modal'], .modal.show .btn-close")
    close_buttons.first&.click if close_buttons.any?
  rescue StandardError
    nil
  end

  def handle_extra_windows!
    handles = @driver.window_handles
    return if handles.size <= 1

    handles[1..].each do |handle|
      @driver.switch_to.window(handle)
      @driver.close
    end

    @driver.switch_to.window(handles.first)
  end

  def visit(path)
    @driver.navigate.to(URI.join(@base_url, path).to_s)
    sleep 1.2
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
    flat = @results.flat_map { |row| row[:tested] || [] }
    tested = flat.count { |item| item[:status]&.start_with?("clicked") }
    useful = flat.count { |item| item[:useful] }
    skipped = flat.count { |item| item[:status] == "skipped" }
    failed = flat.count { |item| item[:status] == "error" }

    report = {
      generated_at: Time.now.utc.iso8601,
      base_url: @base_url,
      screenshot_directory: @screenshots_dir,
      pages: @results,
      summary: {
        total_elements: flat.length,
        clicked_elements: tested,
        useful_actions: useful,
        skipped_destructive: skipped,
        errors: failed
      }
    }

    report_path = File.join(@screenshots_dir, "ui_analysis_report.json")
    File.write(report_path, JSON.pretty_generate(report))

    puts "\nUI analyzer complete"
    puts "Report: #{report_path}"
    puts "Summary: #{report[:summary]}"
  end
end

if __FILE__ == $PROGRAM_NAME
  UIAnalyzer.new.run
end
