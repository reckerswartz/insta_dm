require "rails_helper"

RSpec.describe Instagram::Browser::PageInstrumentation do
  # Fake page whose `on` stashes the handler so tests can invoke it
  # directly. define_singleton_method is used by the real implementation
  # to hang the instrumentation off the page; we mimic that to verify it
  # doesn't regress.
  def fake_page
    klass = Class.new do
      def self.name; "Playwright::Page"; end
      def initialize; @handlers = {}; end
      def on(event, handler); @handlers[event] = handler; end
      def fire(event, *args); @handlers[event]&.call(*args); end
    end
    klass.new
  end

  def fake_console_message(type:, text:)
    Struct.new(:type, :text).new(type, text)
  end

  def fake_request(url:, method: "GET")
    m = method
    Struct.new(:url, :failure) do
      define_method(:method) { m }
    end.new(url, nil)
  end

  def fake_response(url:, status: 200, content_type: "application/json", request:)
    req = request
    Class.new do
      define_method(:url)     { url }
      define_method(:status)  { status }
      define_method(:request) { req }
      define_method(:headers) { { "content-type" => content_type } }
    end.new
  end

  describe ".attach!" do
    it "installs listeners and exposes the instance via page.instrumentation" do
      page = fake_page
      inst = described_class.attach!(page)

      expect(page.instrumentation).to eq(inst)
      expect(inst).to be_a(described_class)
    end

    it "is idempotent: re-attaching returns the same instance" do
      page = fake_page
      first = described_class.attach!(page)
      second = described_class.attach!(page)
      expect(second).to equal(first)
    end
  end

  describe "console capture" do
    it "appends console messages with timestamp, level, message" do
      page = fake_page
      inst = described_class.attach!(page)

      page.fire("console", fake_console_message(type: "warning", text: "hello"))
      page.fire("console", fake_console_message(type: "error", text: "world"))

      entries = inst.selenium_shaped_browser_entries
      expect(entries.length).to eq(2)
      expect(entries.first[:level]).to eq("WARNING")
      expect(entries.first[:message]).to eq("hello")
    end

    it "trims the console buffer to the cap" do
      page = fake_page
      inst = described_class.attach!(page, console_cap: 3, network_cap: 10)

      5.times { |i| page.fire("console", fake_console_message(type: "info", text: "msg #{i}")) }

      entries = inst.selenium_shaped_browser_entries
      expect(entries.length).to eq(3)
      expect(entries.first[:message]).to eq("msg 2")
      expect(entries.last[:message]).to eq("msg 4")
    end
  end

  describe "network capture" do
    it "records requestWillBeSent + responseReceived + loadingFailed" do
      page = fake_page
      inst = described_class.attach!(page)

      req = fake_request(url: "https://example.com/api/v1/ping", method: "GET")
      page.fire("request", req)
      page.fire("response", fake_response(url: "https://example.com/api/v1/ping", status: 200, request: req))
      page.fire("requestfailed", req)

      perf = inst.selenium_shaped_performance_entries
      methods = perf.map { |e| JSON.parse(e["message"]).dig("message", "method") }
      expect(methods).to eq(%w[Network.requestWillBeSent Network.responseReceived Network.loadingFailed])
    end

    it "wraps events into the same shape TaskCaptureSupport's summarize_performance_logs expects" do
      page = fake_page
      inst = described_class.attach!(page)
      req = fake_request(url: "https://example.com/api/v1/direct_v2/threads", method: "POST")
      page.fire("request", req)
      page.fire("response", fake_response(url: "https://example.com/api/v1/direct_v2/threads", status: 200, request: req))

      entries = inst.selenium_shaped_performance_entries
      request_entry = JSON.parse(entries.first["message"])
      expect(request_entry.dig("message", "method")).to eq("Network.requestWillBeSent")
      expect(request_entry.dig("message", "params", "request", "url"))
        .to eq("https://example.com/api/v1/direct_v2/threads")

      response_entry = JSON.parse(entries.last["message"])
      expect(response_entry.dig("message", "params", "response", "url"))
        .to eq("https://example.com/api/v1/direct_v2/threads")
      expect(response_entry.dig("message", "params", "response", "status")).to eq(200)
    end
  end
end
