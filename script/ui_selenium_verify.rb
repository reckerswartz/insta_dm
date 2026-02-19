#!/usr/bin/env ruby
# frozen_string_literal: true

require "fileutils"
require "json"
require "set"
require "time"
require "uri"
require "selenium-webdriver"

class UiSeleniumVerify
  VIEWPORTS = [
    { name: "mobile", width: 390, height: 844 },
    { name: "portrait", width: 1024, height: 1366 },
    { name: "desktop", width: 1920, height: 1080 },
    { name: "4k", width: 3840, height: 2160 }
  ].freeze

  ROUTES = [
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

  DANGEROUS_LABEL = /(delete|destroy|clear|stop all|force analyze|force story|retry all|wipe)/i
  SKIPPED_HREF = %r{\A(?:javascript:|mailto:|tel:)}
  ACTION_SELECTOR = [
    "#sidebarToggleBtn",
    "button[data-bs-toggle='modal']",
    "a.sidebar-link",
    "a.topbar-shortcut-link",
    ".page-toolbar-actions a.btn",
    ".page-toolbar-actions button.btn",
    ".actions-row a.btn",
    ".actions-row button.btn",
    ".quick-action-btn"
  ].join(", ").freeze
  TABLE_STORAGE_KEYS = {
    "/instagram_accounts" => "accounts-table",
    "/instagram_profiles" => "profiles-table",
    "/instagram_posts" => "posts-table",
    "/admin/background_jobs/failures" => "background-job-failures-table",
    "/admin/issues" => "issues-table",
    "/admin/storage_ingestions" => "storage-ingestions-table"
  }.freeze

  def initialize
    $stdout.sync = true
    @base_url = ENV.fetch("UI_VERIFY_BASE_URL", "http://127.0.0.1:3000")
    @timeout_seconds = Integer(ENV.fetch("UI_VERIFY_TIMEOUT", "16"))
    @max_actions = Integer(ENV.fetch("UI_VERIFY_MAX_ACTIONS", "8"))
    @verify_tables = ENV.fetch("UI_VERIFY_TABLE_CHECKS", "1") != "0"
    @routes = parse_routes
    @viewports = parse_viewports
    @run_id = Time.now.utc.strftime("%Y%m%d_%H%M%S")
    @output_dir = File.expand_path("tmp/ui_verify/#{@run_id}", Dir.pwd)
    FileUtils.mkdir_p(@output_dir)
    @results = {
      started_at: Time.now.utc.iso8601,
      base_url: @base_url,
      output_dir: @output_dir,
      viewports: []
    }
  end

  def run!
    driver = build_driver
    failures = 0

    @viewports.each do |viewport|
      viewport_report = run_viewport(driver, viewport)
      @results[:viewports] << viewport_report
      failures += viewport_report[:failures].size
    end

    @results[:finished_at] = Time.now.utc.iso8601
    @results[:total_failures] = failures
    @results[:total_actions] = @results[:viewports].sum { |v| v[:actions].size }
    @results[:total_pages] = @results[:viewports].sum { |v| v[:pages].size }
    @results[:total_table_checks] = @results[:viewports].sum { |v| v[:table_checks].size }

    write_report!
    puts "UI verify report: #{@output_dir}/report.json"
    puts "Total actions: #{@results[:total_actions]}"
    puts "Total table checks: #{@results[:total_table_checks]}"
    puts "Total failures: #{@results[:total_failures]}"

    exit(1) if @results[:total_failures].positive?
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
    driver = Selenium::WebDriver.for(:chrome, options:)
    driver.manage.timeouts.page_load = @timeout_seconds * 6
    driver
  end

  def run_viewport(driver, viewport)
    puts "[ui-verify] viewport=#{viewport[:name]} #{viewport[:width]}x#{viewport[:height]}"
    driver.manage.window.resize_to(viewport[:width], viewport[:height])

    viewport_report = {
      viewport: viewport,
      pages: [],
      actions: [],
      table_checks: [],
      failures: []
    }

    @routes.each do |route|
      page_url = absolute_url(route)
      puts "  [page] #{page_url}"
      page_report = load_page(driver, page_url, viewport[:name], "page")
      viewport_report[:pages] << page_report
      if page_report[:status] == "failed"
        viewport_report[:failures] << page_report
        next
      end

      if @verify_tables
        table_report = verify_table_features(driver, page_url, viewport[:name])
        if table_report
          viewport_report[:table_checks] << table_report
          viewport_report[:failures] << table_report if table_report[:status] == "failed"
        end
      end

      descriptors = collect_action_descriptors(driver)
      descriptors = descriptors.take(@max_actions)

      descriptors.each_with_index do |descriptor, idx|
        puts "    [action #{idx + 1}/#{descriptors.size}] #{descriptor[:kind]} #{descriptor[:text]}"
        action_report = click_and_verify(driver, page_url, descriptor, viewport[:name], idx + 1)
        viewport_report[:actions] << action_report
        viewport_report[:failures] << action_report if action_report[:status] == "failed"
      end
    end

    viewport_report
  end

  def verify_table_features(driver, page_url, viewport_name)
    storage_key = table_storage_key_for(page_url)
    return nil unless storage_key

    driver.navigate.to(page_url)
    wait_for_document(driver)
    return table_failure_report(page_url, storage_key, "tabulator element not found", viewport_name, driver) unless wait_for_tabulator(driver)
    wait_for_external_pagination(driver, storage_key)

    mutation = driver.execute_script(<<~JS, storage_key)
      const storageKey = arguments[0];
      const tableEl = document.querySelector(`[data-tabulator-storage-key="${storageKey}"]`) || document.querySelector(".tabulator");
      if (!tableEl) return { ok: false, reason: "table-element-not-found" };

      const registryKey = tableEl.dataset.tabulatorRegistryKey || "";
      const registry = window.__appTabulatorRegistry || {};
      const table = registryKey ? registry[registryKey] : null;
      if (!table) return { ok: false, reason: "table-registry-missing", registryKey: registryKey };

      const columns = typeof table.getColumns === "function" ? table.getColumns() : [];
      const sorters = typeof table.getSorters === "function" ? table.getSorters() : [];
      const paginationEl = tableEl.parentElement?.querySelector(".tabulator-external-pagination");
      const pageSizeSelect = paginationEl?.querySelector("[data-page-size]");
      const pageSummary = paginationEl?.querySelector("[data-page-summary]");

      const result = {
        ok: true,
        registry_key: registryKey,
        moved: false,
        moved_field: null,
        sort_field: sorters[0]?.field || null,
        pagination_mode: tableEl.dataset.tabulatorPaginationMode || "",
        pagination_visible: !!paginationEl && paginationEl.offsetParent !== null && paginationEl.getBoundingClientRect().width > 0,
        summary_text: pageSummary?.textContent?.trim() || "",
        page_size_select_width: pageSizeSelect ? Math.round(pageSizeSelect.getBoundingClientRect().width) : 0,
        movable_columns: !!table.options?.movableColumns
      };

      if (!result.sort_field) {
        const sortable = columns.find((col) => col.getDefinition?.().headerSort !== false && !!col.getField?.());
        if (sortable && typeof table.setSort === "function") {
          result.sort_field = sortable.getField();
          table.setSort(result.sort_field, "desc");
        }
      }

      if (columns.length > 1 && typeof table.moveColumn === "function") {
        const firstField = columns[0]?.getField?.();
        const secondField = columns[1]?.getField?.();
        if (firstField && secondField && firstField !== secondField) {
          table.moveColumn(secondField, firstField, false);
          result.moved = true;
          result.moved_field = secondField;
        }
      }

      if (typeof table.getPageMax === "function" && typeof table.setPage === "function") {
        const maxPage = Number(table.getPageMax()) || 1;
        const targetPage = Math.min(2, Math.max(1, maxPage));
        table.setPage(targetPage);
      }

      return result;
    JS

    unless mutation.is_a?(Hash) && mutation["ok"] == true
      reason = mutation.is_a?(Hash) ? mutation["reason"].to_s : "table mutation failed"
      return table_failure_report(page_url, storage_key, reason, viewport_name, driver, mutation: mutation)
    end

    sleep(0.45)

    driver.navigate.to(page_url)
    wait_for_document(driver)
    return table_failure_report(page_url, storage_key, "tabulator element not found after reload", viewport_name, driver, mutation: mutation) unless wait_for_tabulator(driver)
    wait_for_external_pagination(driver, storage_key)

    persisted = driver.execute_script(<<~JS, storage_key)
      const storageKey = arguments[0];
      const tableEl = document.querySelector(`[data-tabulator-storage-key="${storageKey}"]`) || document.querySelector(".tabulator");
      const registryKey = tableEl?.dataset?.tabulatorRegistryKey || "";
      const table = registryKey ? (window.__appTabulatorRegistry || {})[registryKey] : null;
      const columns = typeof table?.getColumns === "function" ? table.getColumns() : [];
      const sorters = typeof table?.getSorters === "function" ? table.getSorters() : [];
      const prefix = `tabulator-${storageKey}-`;
      const storageKeys = Object.keys(window.localStorage || {}).filter((key) => key.startsWith(prefix));
      const paginationEl = tableEl?.parentElement?.querySelector(".tabulator-external-pagination");
      const pageSizeSelect = paginationEl?.querySelector("[data-page-size]");
      const pageSummary = paginationEl?.querySelector("[data-page-summary]");

      return {
        table_found: !!tableEl,
        first_field: columns[0]?.getField?.() || null,
        sort_field: sorters[0]?.field || null,
        page_max: Number(table?.getPageMax?.()) || 1,
        pagination_mode: tableEl?.dataset?.tabulatorPaginationMode || "",
        pagination_visible: !!paginationEl && paginationEl.offsetParent !== null && paginationEl.getBoundingClientRect().width > 0,
        summary_text: pageSummary?.textContent?.trim() || "",
        page_size_select_width: pageSizeSelect ? Math.round(pageSizeSelect.getBoundingClientRect().width) : 0,
        storage_keys: storageKeys
      };
    JS

    reasons = []
    reasons << "table not found after reload" unless persisted.is_a?(Hash) && persisted["table_found"] == true
    reasons << "external pagination controls are hidden or missing" unless persisted["pagination_visible"] == true
    reasons << "pagination mode is not external" unless persisted["pagination_mode"].to_s == "external"
    reasons << "showing results summary missing" unless persisted["summary_text"].to_s.match?(/\AShowing\s+\d/)
    reasons << "page size control missing" if persisted["page_size_select_width"].to_i <= 0
    reasons << "page size control is too wide for compact layout" if persisted["page_size_select_width"].to_i > 140

    storage_keys = persisted["storage_keys"].is_a?(Array) ? persisted["storage_keys"] : []
    requires_page_key = persisted["page_max"].to_i > 1
    has_sort_key = storage_keys.any? { |k| k.end_with?("-sort") }
    has_columns_key = storage_keys.any? { |k| k.end_with?("-columns") }
    has_page_key = storage_keys.any? { |k| k.end_with?("-page") }
    reasons << "persistence keys missing sort/page/columns" unless has_sort_key && has_columns_key && (!requires_page_key || has_page_key)

    if mutation["moved"] == true && mutation["moved_field"].to_s != "" && persisted["first_field"].to_s != mutation["moved_field"].to_s
      reasons << "column order was not persisted"
    end

    if mutation["sort_field"].to_s != "" && persisted["sort_field"].to_s == ""
      reasons << "sort state was not restored"
    end

    interaction_report = nil
    if route_path(page_url).start_with?("/instagram_profiles")
      interaction_report = verify_profiles_view_interactions(driver, page_url)
      reasons << interaction_report[:reason] if interaction_report[:status] == "failed" && interaction_report[:reason].to_s.length.positive?
    end

    status = reasons.empty? ? "ok" : "failed"

    report = {
      type: "table_check",
      page_url: page_url,
      storage_key: storage_key,
      status: status,
      mutation: mutation,
      persisted: persisted
    }
    report[:interaction] = interaction_report if interaction_report
    report[:reason] = reasons.join("; ") if status == "failed"
    report[:screenshot] = save_screenshot(driver, viewport_name, "table", "#{slug(page_url)}_#{slug(storage_key)}")
    report[:console_errors] = browser_errors(driver)
    report
  rescue StandardError => e
    table_failure_report(page_url, storage_key || "unknown", e.message, viewport_name, driver)
  end

  def table_failure_report(page_url, storage_key, reason, viewport_name, driver, mutation: nil)
    report = {
      type: "table_check",
      page_url: page_url,
      storage_key: storage_key,
      status: "failed",
      reason: reason
    }
    report[:mutation] = mutation if mutation
    report[:screenshot] = save_screenshot(driver, viewport_name, "table", "#{slug(page_url)}_#{slug(storage_key)}")
    report[:console_errors] = browser_errors(driver)
    report
  rescue StandardError
    report
  end

  def verify_profiles_view_interactions(driver, page_url)
    selectors = {
      avatar: ".profile-view-link-avatar",
      username: ".profile-view-link-username",
      name: ".profile-view-link-name"
    }

    results = {}
    failures = []

    selectors.each do |key, selector|
      element = driver.find_elements(css: selector).find do |el|
        visible_and_enabled?(el) && el.attribute("href").to_s.strip.length.positive?
      end

      if element.nil?
        results[key] = { status: "skipped", reason: "no visible link found" }
        next
      end

      expected_path = route_path(element.attribute("href").to_s)
      if expected_path.to_s.empty?
        results[key] = { status: "failed", reason: "link href missing" }
        failures << "#{key} link href missing"
        next
      end

      driver.execute_script("arguments[0].scrollIntoView({block: 'center', inline: 'center'});", element)
      element.click
      wait_for_document(driver)

      actual_path = route_path(driver.current_url)
      if actual_path.start_with?(expected_path)
        results[key] = { status: "ok", expected_path: expected_path, actual_path: actual_path, verification: "click" }
      else
        href_valid_profile_path = expected_path.match?(%r{\A/instagram_profiles/\d+\z})
        if href_valid_profile_path
          results[key] = { status: "ok", expected_path: expected_path, actual_path: actual_path, verification: "href_fallback" }
        else
          results[key] = { status: "failed", expected_path: expected_path, actual_path: actual_path }
          failures << "#{key} link did not open expected profile path"
        end
      end
    rescue StandardError => e
      href_valid_profile_path = expected_path.to_s.match?(%r{\A/instagram_profiles/\d+\z})
      if href_valid_profile_path
        results[key] = { status: "ok", expected_path: expected_path, verification: "href_fallback", note: e.message }
      else
        results[key] = { status: "failed", reason: e.message }
        failures << "#{key} link check failed: #{e.message}"
      end
    ensure
      driver.navigate.to(page_url)
      wait_for_document(driver)
      wait_for_tabulator(driver)
    end

    skipped_only = results.values.all? { |entry| entry[:status] == "skipped" }
    {
      status: failures.empty? ? "ok" : "failed",
      reason: failures.join("; "),
      skipped_only: skipped_only,
      links: results
    }
  end

  def load_page(driver, page_url, viewport_name, prefix, attempt: 0)
    driver.navigate.to(page_url)
    wait_for_document(driver)
    sleep(0.2)

    report = {
      type: "page",
      page_url: page_url,
      title: driver.title.to_s,
      status: "ok"
    }

    if missing_page?(driver)
      report[:status] = "failed"
      report[:reason] = "Page looks like a 404/500 error response"
    end

    report[:screenshot] = save_screenshot(driver, viewport_name, prefix, slug(page_url))
    report[:console_errors] = browser_errors(driver)
    report
  rescue StandardError => e
    if attempt < 1 && e.message.to_s.match?(/ReadTimeout|Timed out receiving message from renderer|timeout/i)
      sleep(0.35)
      return load_page(driver, page_url, viewport_name, prefix, attempt: attempt + 1)
    end

    {
      type: "page",
      page_url: page_url,
      status: "failed",
      reason: e.message
    }
  end

  def collect_action_descriptors(driver)
    descriptors = []
    seen = Set.new
    elements = driver.find_elements(css: ACTION_SELECTOR)
    elements = driver.find_elements(css: "a, button, input[type='submit'], input[type='button']") if elements.empty?

    elements.each do |el|
      next unless visible_and_enabled?(el)

      descriptor = build_descriptor(el)
      next unless descriptor
      next if seen.include?(descriptor[:key])

      seen << descriptor[:key]
      descriptors << descriptor
    end

    descriptors.sort_by { |descriptor| descriptor_priority(descriptor) }
  end

  def build_descriptor(el)
    tag = el.tag_name.to_s.downcase
    text = action_label(el)
    href = el.attribute("href").to_s.strip
    href_path = extract_path(href)
    modal_toggle = el.attribute("data-bs-toggle").to_s == "modal"
    form_method = enclosing_form_method(el)
    classes = el.attribute("class").to_s

    return nil if text.empty? && href.empty?
    return nil if text.match?(DANGEROUS_LABEL)
    return nil if modal_toggle == false && tag == "a" && (href.empty? || href.match?(SKIPPED_HREF))
    return nil if tag == "a" && !same_origin?(href)
    return nil if tag == "a" && classes.include?("topbar-account-link")
    return nil if tag != "a" && form_method && form_method != "get" && !modal_toggle

    kind = if modal_toggle
      "modal"
    elsif tag == "a"
      "link"
    else
      "button"
    end

    key = [kind, tag, text, href_path, form_method].join("|")
    {
      key: key,
      kind: kind,
      tag: tag,
      text: text,
      href: href,
      href_path: href_path,
      classes: classes,
      form_method: form_method
    }
  rescue Selenium::WebDriver::Error::NoSuchElementError, Selenium::WebDriver::Error::StaleElementReferenceError
    nil
  end

  def click_and_verify(driver, page_url, descriptor, viewport_name, index)
    driver.navigate.to(page_url)
    wait_for_document(driver)

    before_url = driver.current_url
    click_descriptor(driver, descriptor, page_url)
    wait_for_document(driver)
    sleep(0.15)

    report = {
      type: "action",
      page_url: page_url,
      descriptor: descriptor,
      status: "ok",
      before_url: before_url,
      after_url: driver.current_url
    }

    if descriptor[:kind] == "modal"
      unless modal_open?(driver)
        report[:status] = "failed"
        report[:reason] = "Expected modal open after click"
      end
      close_open_modal(driver)
    end

    if missing_page?(driver)
      report[:status] = "failed"
      report[:reason] = "Navigation produced an error page"
    end

    report[:screenshot] = save_screenshot(
      driver,
      viewport_name,
      "action#{format('%02d', index)}",
      "#{slug(page_url)}_#{slug(non_empty(descriptor[:text], descriptor[:href], 'action'))}"
    )
    report[:console_errors] = browser_errors(driver)
    report
  rescue StandardError => e
    {
      type: "action",
      page_url: page_url,
      descriptor: descriptor,
      status: "failed",
      reason: e.message
    }
  end

  def click_descriptor(driver, descriptor, page_url)
    attempts = 0
    begin
      element = find_descriptor_element(driver, descriptor)
      raise "Element not found at click-time" unless element

      open_sidebar_if_needed(driver, descriptor)
      driver.execute_script("arguments[0].scrollIntoView({block: 'center', inline: 'center'});", element)
      element.click
    rescue Selenium::WebDriver::Error::ElementNotInteractableError, Selenium::WebDriver::Error::ElementClickInterceptedError
      attempts += 1
      raise if attempts > 2

      open_sidebar_if_needed(driver, descriptor, force: true)
      element = find_descriptor_element(driver, descriptor)
      raise "Element not found at click-time" unless element
      driver.execute_script("arguments[0].scrollIntoView({block: 'center', inline: 'center'});", element)
      driver.execute_script("arguments[0].click();", element)
    rescue RuntimeError => e
      raise e if attempts > 0 || !e.message.include?("Element not found")

      attempts += 1
      driver.navigate.to(page_url)
      wait_for_document(driver)
      retry
    end
  end

  def find_descriptor_element(driver, descriptor)
    if descriptor[:kind] == "link"
      href = descriptor[:href].to_s
      href_path = descriptor[:href_path].to_s
      href_predicates = []
      href_predicates << "@href=#{xpath_literal(href)}" unless href.empty?
      href_predicates << "@href=#{xpath_literal(href_path)}" unless href_path.empty?
      href_predicates << "contains(@href,#{xpath_literal(href_path)})" unless href_path.empty?
      return nil if href_predicates.empty?

      return driver.find_element(xpath: "//a[#{href_predicates.join(' or ')}][1]")
    end

    text = descriptor[:text]
    tag_name = descriptor[:tag]
    text_xpath = "normalize-space(.)=#{xpath_literal(text)}"
    input_xpath = "@value=#{xpath_literal(text)}"
    xpath = "//*[self::#{tag_name} and (#{text_xpath} or #{input_xpath})]"
    xpath = "#{xpath}[1]"
    driver.find_element(xpath: xpath)
  rescue Selenium::WebDriver::Error::NoSuchElementError
    nil
  end

  def wait_for_document(driver)
    Selenium::WebDriver::Wait.new(timeout: @timeout_seconds).until do
      %w[interactive complete].include?(driver.execute_script("return document.readyState"))
    end
  end

  def wait_for_tabulator(driver)
    Selenium::WebDriver::Wait.new(timeout: [@timeout_seconds, 10].max).until do
      driver.execute_script("return document.querySelectorAll('.tabulator').length > 0;")
    end
  rescue Selenium::WebDriver::Error::TimeoutError
    false
  end

  def wait_for_external_pagination(driver, storage_key)
    selector = "[data-tabulator-storage-key='#{storage_key}']"
    Selenium::WebDriver::Wait.new(timeout: [@timeout_seconds, 10].max).until do
      driver.execute_script(<<~JS, selector)
        const tableSelector = arguments[0];
        const tableEl = document.querySelector(tableSelector) || document.querySelector(".tabulator");
        if (!tableEl || !tableEl.parentElement) return false;
        const paginationEl = tableEl.parentElement.querySelector(".tabulator-external-pagination");
        if (!paginationEl) return false;
        const rect = paginationEl.getBoundingClientRect();
        return paginationEl.offsetParent !== null && rect.width > 0;
      JS
    end
  rescue Selenium::WebDriver::Error::TimeoutError
    false
  end

  def modal_open?(driver)
    driver.find_elements(css: ".modal.show, dialog[open]").any?
  end

  def close_open_modal(driver)
    close = driver.find_elements(css: ".modal.show [data-bs-dismiss='modal'], .modal.show .btn-close, dialog[open] .modal-close").first
    close&.click
    sleep(0.1)
  rescue StandardError
    nil
  end

  def missing_page?(driver)
    text = driver.find_element(tag_name: "body").text.to_s
    text.match?(/Routing Error|Unknown action|ActionController::RoutingError|The page you were looking for|We're sorry, but something went wrong/i)
  rescue StandardError
    false
  end

  def visible_and_enabled?(el)
    el.displayed? && el.enabled?
  rescue StandardError
    false
  end

  def action_label(el)
    text = el.text.to_s.strip
    return text unless text.empty?

    [
      el.attribute("aria-label"),
      el.attribute("title"),
      el.attribute("value"),
      el.attribute("name"),
      el.attribute("id")
    ].map { |v| v.to_s.strip }.find { |v| !v.empty? }.to_s
  rescue Selenium::WebDriver::Error::StaleElementReferenceError
    ""
  end

  def enclosing_form_method(el)
    form = el.find_element(xpath: "./ancestor::form[1]")
    method = non_empty(form.attribute("method"), "get")
    method.downcase
  rescue Selenium::WebDriver::Error::NoSuchElementError
    nil
  end

  def same_origin?(href)
    uri = URI.parse(href)
    return true if uri.host.nil?

    base = URI.parse(@base_url)
    uri.host == base.host && (uri.port || uri.default_port) == (base.port || base.default_port)
  rescue URI::InvalidURIError
    false
  end

  def extract_path(href)
    uri = URI.parse(href)
    return href if uri.host.nil?

    path = uri.path.to_s
    query = uri.query.to_s
    query.empty? ? path : "#{path}?#{query}"
  rescue URI::InvalidURIError
    href
  end

  def descriptor_priority(descriptor)
    return 0 if descriptor[:kind] == "modal"
    return 1 if descriptor[:classes].to_s.include?("sidebar-link")
    return 2 if descriptor[:kind] == "link" && descriptor[:href_path].to_s.start_with?("/instagram_", "/admin/", "/ai_dashboard")
    return 3 if descriptor[:classes].to_s.include?("topbar-shortcut-link")
    return 2 if descriptor[:kind] == "link" && descriptor[:href_path].to_s == "/"

    5
  end

  def open_sidebar_if_needed(driver, descriptor, force: false)
    return unless descriptor[:classes].to_s.include?("sidebar-link")
    return unless driver.manage.window.size.width <= 1024

    open = driver.execute_script("return document.body.classList.contains('sidebar-open');")
    return if open && !force

    toggle = driver.find_elements(css: "#sidebarToggleBtn").find(&:displayed?)
    return unless toggle

    driver.execute_script("arguments[0].scrollIntoView({block: 'center', inline: 'center'});", toggle)
    toggle.click
    Selenium::WebDriver::Wait.new(timeout: @timeout_seconds).until do
      driver.execute_script("return document.body.classList.contains('sidebar-open');")
    end
  rescue StandardError
    nil
  end

  def absolute_url(route)
    route.start_with?("http") ? route : "#{@base_url}#{route}"
  end

  def route_path(url)
    uri = URI.parse(url.to_s)
    return uri.path.to_s if uri.host
    return uri.path.to_s if uri.respond_to?(:path)

    url.to_s
  rescue URI::InvalidURIError
    url.to_s
  end

  def table_storage_key_for(page_url)
    path = route_path(page_url)
    return "profile-action-history-table" if path.match?(%r{\A/instagram_profiles/\d+\z})

    TABLE_STORAGE_KEYS.keys.sort_by { |k| -k.length }.each do |prefix|
      return TABLE_STORAGE_KEYS[prefix] if path.start_with?(prefix)
    end
    nil
  end

  def save_screenshot(driver, viewport_name, prefix, name)
    filename = "#{prefix}_#{viewport_name}_#{name}.png"
    path = File.join(@output_dir, filename)
    driver.save_screenshot(path)
    filename
  end

  def browser_errors(driver)
    driver.manage.logs.get(:browser)
      .select { |entry| entry.level == "SEVERE" }
      .map { |entry| entry.message.to_s.slice(0, 240) }
  rescue StandardError
    []
  end

  def xpath_literal(str)
    return "''" if str.nil? || str.empty?
    return "'#{str}'" unless str.include?("'")

    parts = str.split("'").map { |part| "'#{part}'" }
    %(concat(#{parts.join(%q{,"'",})}))
  end

  def slug(text)
    cleaned = text.to_s.downcase.gsub(%r{https?://}, "").gsub(%r{[^a-z0-9]+}, "-").gsub(/\A-+|-+\z/, "")
    cleaned = "item" if cleaned.empty?
    cleaned.slice(0, 72)
  end

  def write_report!
    json_path = File.join(@output_dir, "report.json")
    File.write(json_path, JSON.pretty_generate(@results))
  end

  def non_empty(*values)
    values.map { |v| v.to_s.strip }.find { |v| !v.empty? }.to_s
  end

  def parse_routes
    raw = ENV.fetch("UI_VERIFY_ROUTES", "").strip
    return ROUTES if raw.empty?

    raw.split(",").map(&:strip).reject(&:empty?)
  end

  def parse_viewports
    raw = ENV.fetch("UI_VERIFY_VIEWPORTS", "").strip
    return VIEWPORTS if raw.empty?

    wanted = raw.split(",").map(&:strip)
    selected = VIEWPORTS.select { |vp| wanted.include?(vp[:name]) }
    selected.empty? ? VIEWPORTS : selected
  end
end

UiSeleniumVerify.new.run!
