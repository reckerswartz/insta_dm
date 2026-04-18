require "rails_helper"

RSpec.describe Instagram::Client::TaskCaptureSupport do
  def fake_selenium_driver(**attrs)
    klass = Class.new { def self.name; "Selenium::WebDriver::Driver"; end }
    inst = klass.new
    attrs.each do |m, v|
      inst.define_singleton_method(m) { |*a, **kw| v.respond_to?(:call) ? v.call(*a, **kw) : v }
    end
    inst
  end

  def fake_playwright_page(instrumentation: nil, **attrs)
    klass = Class.new { def self.name; "Playwright::Page"; end }
    inst = klass.new
    attrs.each do |m, v|
      inst.define_singleton_method(m) { |*a, **kw| v.respond_to?(:call) ? v.call(*a, **kw) : v }
    end
    inst.define_singleton_method(:instrumentation) { instrumentation } if instrumentation
    inst
  end

  let(:client) do
    account = InstagramAccount.create!(username: "tc_#{SecureRandom.hex(4)}")
    Instagram::Client.new(account: account)
  end

  before do
    @capture_root = Pathname.new(Dir.mktmpdir("tc_spec_"))
    stub_const("Instagram::Client::DEBUG_CAPTURE_DIR", @capture_root)
  end

  after do
    FileUtils.rm_rf(@capture_root) if @capture_root
  end

  describe "#capture_task_html on the Playwright path" do
    it "writes HTML, JSON, and screenshot using page.content / page.url / page.screenshot" do
      screenshot_calls = []
      page = fake_playwright_page(
        content: "<html><body>Playwright HTML</body></html>",
        url: "https://www.instagram.com/",
        title: "Instagram",
        screenshot: ->(path:) { screenshot_calls << path; FileUtils.touch(path); true }
      )

      client.send(:capture_task_html, driver: page, task_name: "smoke_task", status: "ok", meta: { extra: "hi" })

      today_dir = @capture_root.join(Time.current.utc.strftime("%Y%m%d"))
      json = Dir.children(today_dir).find { |f| f.end_with?("smoke_task_ok.json") }
      html = Dir.children(today_dir).find { |f| f.end_with?("smoke_task_ok.html") }
      png = Dir.children(today_dir).find { |f| f.end_with?("smoke_task_ok.png") }

      expect(json).to be_present
      expect(html).to be_present
      expect(png).to be_present
      expect(screenshot_calls.first).to include("smoke_task_ok.png")

      metadata = JSON.parse(File.read(today_dir.join(json)))
      expect(metadata["current_url"]).to eq("https://www.instagram.com/")
      expect(metadata["page_title"]).to eq("Instagram")
      expect(metadata["status"]).to eq("ok")
      expect(metadata["extra"]).to eq("hi")
    end

    it "includes browser_console + performance_summary when instrumentation is attached" do
      instrumentation = double(
        "PageInstrumentation",
        selenium_shaped_browser_entries: [
          { timestamp: 1, level: "SEVERE", message: "oh no" }
        ],
        selenium_shaped_performance_entries: [
          {
            "timestamp" => 1,
            "message" => {
              "message" => {
                "method" => "Network.requestWillBeSent",
                "params" => { "requestId" => "r1", "request" => { "url" => "https://i.instagram.com/api/v1/feed/", "method" => "GET" } }
              }
            }.to_json
          },
          {
            "timestamp" => 2,
            "message" => {
              "message" => {
                "method" => "Network.responseReceived",
                "params" => { "requestId" => "r1", "response" => { "url" => "https://i.instagram.com/api/v1/feed/", "status" => 200, "mimeType" => "application/json" } }
              }
            }.to_json
          }
        ]
      )
      page = fake_playwright_page(
        instrumentation: instrumentation,
        content: "<html></html>",
        url: "https://i.instagram.com/",
        title: "t",
        screenshot: ->(path:) { FileUtils.touch(path); true }
      )

      client.send(:capture_task_html, driver: page, task_name: "smoke_logs", status: "ok")

      today_dir = @capture_root.join(Time.current.utc.strftime("%Y%m%d"))
      json_file = Dir.children(today_dir).find { |f| f.end_with?("smoke_logs_ok.json") }
      metadata = JSON.parse(File.read(today_dir.join(json_file)))

      expect(metadata["browser_console"].first["message"]).to eq("oh no")
      expect(metadata.dig("performance_summary", "interesting_request_count")).to eq(1)
      expect(metadata.dig("performance_summary", "recent_interesting", 0, "url"))
        .to eq("https://i.instagram.com/api/v1/feed/")
      expect(metadata.dig("performance_summary", "recent_interesting", 0, "response", "status")).to eq(200)
    end

    it "degrades gracefully when instrumentation is missing" do
      page = fake_playwright_page(
        content: "<html></html>",
        url: "https://example.com/",
        title: "x",
        screenshot: ->(path:) { FileUtils.touch(path); true }
      )

      expect {
        client.send(:capture_task_html, driver: page, task_name: "no_instr", status: "ok")
      }.not_to raise_error
    end
  end

  describe "#capture_task_html on the Selenium path" do
    it "still uses page_source / current_url / save_screenshot" do
      screenshot_calls = []
      driver = fake_selenium_driver(
        page_source: "<html>selenium</html>",
        current_url: "https://www.instagram.com/",
        title: "IG",
        save_screenshot: ->(path) { screenshot_calls << path; FileUtils.touch(path); true }
      )

      client.send(:capture_task_html, driver: driver, task_name: "sel_task", status: "ok")

      today_dir = @capture_root.join(Time.current.utc.strftime("%Y%m%d"))
      html_file = Dir.children(today_dir).find { |f| f.end_with?("sel_task_ok.html") }
      expect(File.read(today_dir.join(html_file))).to eq("<html>selenium</html>")
      expect(screenshot_calls.first).to include("sel_task_ok.png")
    end
  end

  describe "#with_task_capture" do
    it "writes an ok capture and returns the block value" do
      page = fake_playwright_page(
        content: "<html></html>", url: "https://x.com/", title: "x",
        screenshot: ->(path:) { FileUtils.touch(path); true }
      )

      value = client.send(:with_task_capture, driver: page, task_name: "wrap_ok") { 42 }
      expect(value).to eq(42)

      today_dir = @capture_root.join(Time.current.utc.strftime("%Y%m%d"))
      expect(Dir.children(today_dir).any? { |f| f.include?("wrap_ok_ok") }).to be(true)
    end

    it "writes an error capture and re-raises" do
      page = fake_playwright_page(
        content: "<html></html>", url: "https://x.com/", title: "x",
        screenshot: ->(path:) { FileUtils.touch(path); true }
      )

      expect {
        client.send(:with_task_capture, driver: page, task_name: "wrap_err") { raise "boom" }
      }.to raise_error("boom")

      today_dir = @capture_root.join(Time.current.utc.strftime("%Y%m%d"))
      err_file = Dir.children(today_dir).find { |f| f.include?("wrap_err_error.json") }
      expect(err_file).to be_present
      metadata = JSON.parse(File.read(today_dir.join(err_file)))
      expect(metadata["error_class"]).to eq("RuntimeError")
      expect(metadata["error_message"]).to eq("boom")
    end
  end
end
