require "fileutils"
require "json"
require "net/http"
require "selenium-webdriver"
require "time"
require "uri"

module Diagnostics
  module SeleniumWorkflowHelpers
    def ui_workflow_base_url
      ENV.fetch("UI_AUDIT_BASE_URL", "http://127.0.0.1:3000")
    end

    def ui_workflow_server_up?
      uri = URI.join(ui_workflow_base_url, "/up")
      response = Net::HTTP.get_response(uri)
      response.code.to_i == 200
    rescue StandardError
      false
    end

    def build_workflow_driver
      options = Selenium::WebDriver::Chrome::Options.new
      options.add_argument("--headless=new") unless ENV["UI_HEADFUL"] == "1"
      options.add_argument("--disable-gpu")
      options.add_argument("--no-sandbox")
      options.add_argument("--disable-dev-shm-usage")
      options.add_argument("--window-size=1680,1050")
      options.add_option("goog:loggingPrefs", { browser: "ALL", performance: "ALL" })
      options.page_load_strategy = "eager"

      driver = Selenium::WebDriver.for(:chrome, options: options)
      driver.manage.timeouts.page_load = 45
      driver.manage.timeouts.script = 25
      driver
    end

    def with_workflow_driver(example, driver: nil)
      created_driver = driver.nil?
      driver ||= build_workflow_driver
      yield(driver)
    rescue StandardError => e
      capture_workflow_failure_artifacts(example: example, driver: driver, error: e)
      raise
    ensure
      driver&.quit if created_driver
    end

    def wait_for_dom_ready(driver, timeout: 12)
      Selenium::WebDriver::Wait.new(timeout: timeout).until do
        state = driver.execute_script("return document.readyState")
        %w[interactive complete].include?(state)
      end
    end

    def wait_for_selector(driver, css:, timeout: 12)
      Selenium::WebDriver::Wait.new(timeout: timeout).until do
        node = driver.find_elements(css: css).find(&:displayed?)
        node if node
      end
    end

    def wait_for_text(driver, css:, pattern:, timeout: 12)
      matcher = pattern.is_a?(Regexp) ? pattern : /#{Regexp.escape(pattern.to_s)}/i
      Selenium::WebDriver::Wait.new(timeout: timeout).until do
        node = driver.find_elements(css: css).find(&:displayed?)
        next false unless node

        matcher.match?(node.text.to_s)
      end
    end

    def inject_workflow_probe(driver)
      driver.execute_script(<<~JS)
        if (!window.__workflowProbeInstalled) {
          window.__workflowProbeInstalled = true;
          window.__workflowProbe = {
            uncaught: [],
            rejections: [],
            failedRequests: [],
            generateRequests: { triggerCalls: 0, statusCalls: 0 }
          };

          window.addEventListener("error", function(event) {
            window.__workflowProbe.uncaught.push(String(event && event.message || "error"));
          });

          window.addEventListener("unhandledrejection", function(event) {
            const reason = event && event.reason;
            window.__workflowProbe.rejections.push(String(reason && reason.message ? reason.message : reason || "rejection"));
          });

          if (!window.__workflowProbeWrappedFetch && window.fetch) {
            window.__workflowProbeWrappedFetch = true;
            const originalFetch = window.fetch.bind(window);
            window.fetch = function() {
              const req = arguments[0];
              const init = arguments[1] || {};
              const url = (typeof req === "string") ? req : (req && req.url ? req.url : "");
              const body = String((init && init.body) || "");
              const isGenerate = url.indexOf("/generate_llm_comment") >= 0;
              const isStatusOnly = body.indexOf('"status_only":true') >= 0 || body.indexOf('"status_only":"true"') >= 0;
              if (isGenerate) {
                if (isStatusOnly) {
                  window.__workflowProbe.generateRequests.statusCalls += 1;
                } else {
                  window.__workflowProbe.generateRequests.triggerCalls += 1;
                }
              }

              return originalFetch.apply(window, arguments).then(function(response) {
                if (!response.ok) {
                  window.__workflowProbe.failedRequests.push({
                    url: url,
                    status: Number(response.status || 0),
                    statusText: String(response.statusText || "")
                  });
                }
                return response;
              }).catch(function(error) {
                window.__workflowProbe.failedRequests.push({
                  url: url,
                  status: 0,
                  statusText: String(error && error.message || "network_error")
                });
                throw error;
              });
            };
          }
        }
      JS
    end

    def read_workflow_probe(driver)
      payload = driver.execute_script("return window.__workflowProbe || {};")
      payload.is_a?(Hash) ? payload : {}
    rescue StandardError
      {}
    end

    private

    def capture_workflow_failure_artifacts(example:, driver:, error:)
      return unless driver

      output_dir = Rails.root.join("tmp", "diagnostic_specs", "workflow_failures")
      FileUtils.mkdir_p(output_dir)

      timestamp = Time.now.utc.strftime("%Y%m%dT%H%M%SZ")
      slug = example.full_description.to_s.downcase.gsub(/[^a-z0-9]+/, "_").gsub(/\A_+|_+\z/, "").slice(0, 90)
      base = "#{timestamp}_#{slug.presence || "workflow"}"

      screenshot_path = output_dir.join("#{base}.png")
      driver.save_screenshot(screenshot_path.to_s)

      browser_logs = driver.manage.logs.get(:browser).map do |entry|
        { level: entry.level.to_s, message: entry.message.to_s, timestamp: entry.timestamp }
      end

      performance_logs = driver.manage.logs.get(:performance).last(250).map do |entry|
        { level: entry.level.to_s, message: entry.message.to_s, timestamp: entry.timestamp }
      end

      details = {
        example: example.full_description,
        error_class: error.class.name,
        error_message: error.message.to_s,
        current_url: driver.current_url,
        screenshot: screenshot_path.to_s,
        browser_logs: browser_logs,
        performance_logs: performance_logs
      }
      File.write(output_dir.join("#{base}.json"), JSON.pretty_generate(details))
    rescue StandardError
      nil
    end
  end
end

RSpec.configure do |config|
  config.include Diagnostics::SeleniumWorkflowHelpers, :ui_workflow
end
