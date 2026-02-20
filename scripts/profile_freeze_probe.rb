#!/usr/bin/env ruby

require "fileutils"
require "json"
require "net/http"
require "selenium-webdriver"
require "time"
require "uri"

class ProfileFreezeProbe
  WAIT_TIMEOUT = 22

  def initialize
    @base_url = ENV.fetch("UI_BASE_URL", "http://127.0.0.1:3000")
    @account_id = ENV.fetch("PROFILE_PROBE_ACCOUNT_ID", "2")
    @forced_profile_path = ENV["PROFILE_PROBE_PROFILE_PATH"]

    timestamp = Time.now.utc.strftime("%Y%m%d_%H%M%S")
    @output_dir = File.join(Dir.pwd, "tmp", "profile_freeze_probe", timestamp)
    FileUtils.mkdir_p(@output_dir)

    @driver = Selenium::WebDriver.for(:chrome, options: build_options)
    @driver.manage.timeouts.page_load = WAIT_TIMEOUT
    @driver.manage.timeouts.script_timeout = WAIT_TIMEOUT
  end

  def run
    ensure_server_online!
    install_probe_hooks

    profile_path = nil
    if forced_profile_path?
      profile_path = @forced_profile_path
      puts "Using forced profile path: #{profile_path}"
    else
      account_path = "/instagram_accounts/#{@account_id}"
      puts "Opening account page: #{account_path}"
      nav_to(account_path)
      wait_for_ready_state
      sleep(0.5)
      profile_path = resolve_profile_path
    end

    raise "No profile path could be discovered." if profile_path.to_s.empty?

    puts "Opening profile page: #{profile_path}"
    open_started_at = monotonic_time
    nav_to(profile_path)
    wait_for_ready_state
    wait_for_profile_page
    open_duration_ms = ((monotonic_time - open_started_at) * 1000.0).round(1)

    sleep(1.3)
    screenshot_path = screenshot("profile_loaded")
    payload = gather_report(profile_path: profile_path, open_duration_ms: open_duration_ms, screenshot_path: screenshot_path)
    report_path = File.join(@output_dir, "report.json")
    File.write(report_path, JSON.pretty_generate(payload))

    puts "Probe complete."
    puts "Profile open duration: #{open_duration_ms}ms"
    puts "Report: #{report_path}"
    puts "Screenshot: #{screenshot_path}"
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
    options.add_argument("--window-size=1600,1000")
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
          window.__profileProbe = {
            startedAt: Date.now(),
            longTaskCount: 0,
            longTaskTotalMs: 0,
            longTaskMaxMs: 0,
            errors: []
          };

          window.addEventListener("error", (event) => {
            const msg = String(event.message || "window_error");
            const src = String(event.filename || "");
            window.__profileProbe.errors.push(`[error] ${msg} ${src}`.trim());
          });

          window.addEventListener("unhandledrejection", (event) => {
            const reason = event.reason && event.reason.message ? event.reason.message : String(event.reason || "unhandled_rejection");
            window.__profileProbe.errors.push(`[promise] ${reason}`);
          });

          if (window.PerformanceObserver && PerformanceObserver.supportedEntryTypes && PerformanceObserver.supportedEntryTypes.includes("longtask")) {
            const observer = new PerformanceObserver((list) => {
              for (const entry of list.getEntries()) {
                window.__profileProbe.longTaskCount += 1;
                window.__profileProbe.longTaskTotalMs += entry.duration;
                if (entry.duration > window.__profileProbe.longTaskMaxMs) {
                  window.__profileProbe.longTaskMaxMs = entry.duration;
                }
              }
            });
            observer.observe({ entryTypes: ["longtask"] });
          }
        })();
      JS
    )
  rescue StandardError => e
    puts "Warning: unable to install long-task probe hooks: #{e.message}"
  end

  def resolve_profile_path
    forced = @forced_profile_path.to_s.strip
    return forced if forced.start_with?("/instagram_profiles/")

    profiles_path = "/instagram_profiles"
    nav_to(profiles_path)
    wait_for_ready_state

    wait = Selenium::WebDriver::Wait.new(timeout: WAIT_TIMEOUT)
    wait.until do
      links = @driver.find_elements(css: "a[href^='/instagram_profiles/']")
      links.any?
    end

    href = @driver.find_elements(css: "a[href^='/instagram_profiles/']")
                  .map { |el| el.attribute("href") }
                  .compact
                  .find { |value| URI(value).path.match?(%r{^/instagram_profiles/\d+$}) rescue false }

    href ? URI(href).path : nil
  rescue StandardError => e
    puts "Warning: could not discover profile link from /instagram_profiles: #{e.message}"
    nil
  end

  def forced_profile_path?
    path = @forced_profile_path.to_s
    path.start_with?("/instagram_profiles/")
  end

  def wait_for_profile_page
    wait = Selenium::WebDriver::Wait.new(timeout: WAIT_TIMEOUT)
    wait.until do
      @driver.current_url.include?("/instagram_profiles/") &&
        @driver.find_elements(css: "section.card").any?
    end
  end

  def gather_report(profile_path:, open_duration_ms:, screenshot_path:)
    page_metrics = @driver.execute_script(<<~JS)
      return (() => {
        const nav = performance.getEntriesByType("navigation")[0];
        const resources = performance.getEntriesByType("resource");
        const aggregate = resources.reduce((memo, item) => {
          memo.total += 1;
          memo.durationMs += Number(item.duration || 0);
          memo.transferBytes += Number(item.transferSize || 0);

          const name = String(item.name || "");
          if (name.includes(".mp4") || name.includes(".mov")) memo.videoRequests += 1;
          if (name.includes(".jpg") || name.includes(".jpeg") || name.includes(".png") || name.includes(".webp")) memo.imageRequests += 1;
          if (name.includes(".js")) memo.jsRequests += 1;
          if (name.includes(".css")) memo.cssRequests += 1;
          return memo;
        }, {
          total: 0,
          durationMs: 0,
          transferBytes: 0,
          videoRequests: 0,
          imageRequests: 0,
          jsRequests: 0,
          cssRequests: 0
        });

        return {
          readyState: document.readyState,
          title: document.title,
          nav: nav ? {
            domInteractiveMs: Number(nav.domInteractive || 0),
            domContentLoadedMs: Number(nav.domContentLoadedEventEnd || 0),
            loadEventMs: Number(nav.loadEventEnd || 0),
            responseEndMs: Number(nav.responseEnd || 0),
            transferSize: Number(nav.transferSize || 0)
          } : null,
          dom: {
            videos: document.querySelectorAll("video").length,
            images: document.querySelectorAll("img").length,
            storyCards: document.querySelectorAll(".story-media-card").length,
            plyrPlayers: document.querySelectorAll(".plyr").length,
            tableRows: document.querySelectorAll("tr").length
          },
          resources: aggregate,
          probe: window.__profileProbe || null
        };
      })();
    JS

    jank = @driver.execute_async_script(<<~JS)
      const done = arguments[0];
      let frames = 0;
      let prev = performance.now();
      let maxDelta = 0;
      let over50 = 0;

      function step(now) {
        const delta = now - prev;
        if (delta > maxDelta) maxDelta = delta;
        if (delta > 50) over50 += 1;
        prev = now;
        frames += 1;
        if (frames >= 120) {
          done({ maxFrameDeltaMs: maxDelta, framesOver50Ms: over50 });
          return;
        }
        requestAnimationFrame(step);
      }

      requestAnimationFrame(step);
    JS

    {
      generated_at: Time.now.utc.iso8601,
      base_url: @base_url,
      account_id: @account_id,
      profile_path: profile_path,
      profile_open_duration_ms: open_duration_ms,
      screenshot: screenshot_path,
      page_metrics: page_metrics,
      frame_jank: jank
    }
  end

  def wait_for_ready_state
    wait = Selenium::WebDriver::Wait.new(timeout: WAIT_TIMEOUT)
    wait.until do
      @driver.execute_script("return document.readyState") == "complete"
    end
  end

  def nav_to(path)
    @driver.navigate.to(URI.join(@base_url, path).to_s)
  end

  def screenshot(name)
    filename = "#{name.to_s.gsub(/[^a-zA-Z0-9_-]+/, "_")}.png"
    path = File.join(@output_dir, filename)
    @driver.save_screenshot(path)
    path
  end

  def monotonic_time
    Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end
end

if __FILE__ == $PROGRAM_NAME
  ProfileFreezeProbe.new.run
end
