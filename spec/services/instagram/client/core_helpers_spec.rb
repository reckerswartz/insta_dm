require "rails_helper"

RSpec.describe Instagram::Client::CoreHelpers do
  def fake_selenium_driver(**attrs)
    klass = Class.new { def self.name; "Selenium::WebDriver::Driver"; end }
    inst = klass.new
    attrs.each do |m, v|
      inst.define_singleton_method(m) { |*a, **kw| v.respond_to?(:call) ? v.call(*a, **kw) : v }
    end
    inst
  end

  def fake_playwright_page(**attrs)
    klass = Class.new { def self.name; "Playwright::Page"; end }
    inst = klass.new
    attrs.each do |m, v|
      inst.define_singleton_method(m) { |*a, **kw| v.respond_to?(:call) ? v.call(*a, **kw) : v }
    end
    inst
  end

  let(:client) do
    account = InstagramAccount.create!(username: "ch_#{SecureRandom.hex(4)}")
    Instagram::Client.new(account: account)
  end

  describe "#element_enabled?" do
    it "returns false for nil" do
      expect(client.send(:element_enabled?, nil)).to be(false)
    end

    it "treats a Selenium WebElement as enabled when displayed and not disabled" do
      el = double("WebElement", displayed?: true)
      allow(el).to receive(:attribute).with("disabled").and_return(nil)
      allow(el).to receive(:attribute).with("aria-disabled").and_return("false")

      expect(client.send(:element_enabled?, el)).to be(true)
    end

    it "treats a Selenium WebElement as disabled when attribute('disabled') is present" do
      el = double("WebElement", displayed?: true)
      allow(el).to receive(:attribute).with("disabled").and_return("disabled")
      allow(el).to receive(:attribute).with("aria-disabled").and_return(nil)

      expect(client.send(:element_enabled?, el)).to be(false)
    end

    it "uses get_attribute on a Playwright locator" do
      locator = double("Locator", visible?: true)
      allow(locator).to receive(:get_attribute).with("disabled").and_return(nil)
      allow(locator).to receive(:get_attribute).with("aria-disabled").and_return("false")

      expect(client.send(:element_enabled?, locator)).to be(true)
    end

    it "treats aria-disabled='true' as disabled on the Playwright path" do
      locator = double("Locator", visible?: true)
      allow(locator).to receive(:get_attribute).with("disabled").and_return(nil)
      allow(locator).to receive(:get_attribute).with("aria-disabled").and_return("true")

      expect(client.send(:element_enabled?, locator)).to be(false)
    end
  end

  describe "#wait_for / #wait_for_present" do
    it "calls locator(css).first.wait_for(state: 'visible', ...) on the Playwright path" do
      locator = double("Locator")
      first = double("Locator.first")
      allow(locator).to receive(:first).and_return(first)
      expect(first).to receive(:wait_for).with(state: "visible", timeout: 10_000)

      page = fake_playwright_page(locator: locator)

      result = client.send(:wait_for, page, css: ".foo", timeout: 10)
      expect(result).to eq(first)
    end

    it "prefixes xpath with 'xpath=' on the Playwright path" do
      captured = nil
      locator_first = double("first")
      allow(locator_first).to receive(:wait_for)
      page = fake_playwright_page(locator: ->(sel) { captured = sel; double("Locator", first: locator_first) })

      client.send(:wait_for, page, xpath: "//button[1]", timeout: 5)
      expect(captured).to eq("xpath=//button[1]")
    end

    it "returns true from wait_for_present on the Playwright path" do
      first = double("first"); allow(first).to receive(:wait_for)
      locator = double("Locator", first: first)
      page = fake_playwright_page(locator: locator)

      expect(client.send(:wait_for_present, page, css: ".x", timeout: 2)).to be(true)
    end

    it "falls through to Selenium::WebDriver::Wait on the Selenium path" do
      el = double("WebElement", displayed?: true)
      driver = fake_selenium_driver(find_elements: [el])
      expect(Selenium::WebDriver::Wait).to receive(:new).with(timeout: 5).and_call_original
      # The existing Selenium implementation's `return` unwinds rspec; we just
      # need to verify dispatch by checking that find_elements was called.
      begin
        client.send(:wait_for, driver, css: ".x", timeout: 5)
      rescue LocalJumpError
        # expected: `return` from inside wait.until block
      end
    end
  end

  describe "#maybe_capture_filmstrip" do
    around do |ex|
      original = ENV["INSTAGRAM_FILMSTRIP"]
      begin
        ex.run
      ensure
        ENV["INSTAGRAM_FILMSTRIP"] = original
      end
    end

    it "is a no-op when INSTAGRAM_FILMSTRIP is unset on both driver types" do
      ENV.delete("INSTAGRAM_FILMSTRIP")

      expect {
        client.send(:maybe_capture_filmstrip, fake_playwright_page, label: "x", seconds: 0, interval: 0)
        client.send(:maybe_capture_filmstrip, fake_selenium_driver, label: "x", seconds: 0, interval: 0)
      }.not_to raise_error
    end

    it "calls page.screenshot(path:) on the Playwright path" do
      ENV["INSTAGRAM_FILMSTRIP"] = "1"
      calls = []
      page = fake_playwright_page(screenshot: ->(**kw) { calls << kw; true })

      Dir.mktmpdir do |tmp|
        stub_const("Instagram::Client::DEBUG_CAPTURE_DIR", Pathname.new(tmp))
        # 0.0s duration but non-zero interval makes one pass through the loop.
        client.send(:maybe_capture_filmstrip, page, label: "lbl", seconds: 0.001, interval: 0.001)
      end

      expect(calls).not_to be_empty
      expect(calls.first[:path]).to include("filmstrip_lbl")
    end

    it "calls driver.save_screenshot(path) on the Selenium path" do
      ENV["INSTAGRAM_FILMSTRIP"] = "1"
      calls = []
      driver = fake_selenium_driver(save_screenshot: ->(path) { calls << path; true })

      Dir.mktmpdir do |tmp|
        stub_const("Instagram::Client::DEBUG_CAPTURE_DIR", Pathname.new(tmp))
        client.send(:maybe_capture_filmstrip, driver, label: "lbl", seconds: 0.001, interval: 0.001)
      end

      expect(calls).not_to be_empty
      expect(calls.first).to include("filmstrip_lbl")
    end
  end

  describe "#detect_websocket_tls_issue" do
    it "returns the stub when a Playwright page has no instrumentation attached" do
      page = fake_playwright_page
      expect(client.send(:detect_websocket_tls_issue, page))
        .to include(found: false, reason: "tls_probe_unavailable_on_playwright")
    end

    it "consumes instrumentation console entries on the Playwright path and flags the IG WS TLS failure" do
      instrumentation = double(
        "PageInstrumentation",
        selenium_shaped_browser_entries: [
          { timestamp: 1, level: "SEVERE",
            message: "gateway.instagram.com/ws/streamcontroller net::ERR_CERT_AUTHORITY_INVALID something" }
        ]
      )
      page = fake_playwright_page(instrumentation: instrumentation)
      result = client.send(:detect_websocket_tls_issue, page)
      expect(result[:found]).to be(true)
      expect(result[:reason]).to eq("ERR_CERT_AUTHORITY_INVALID")
    end

    it "returns { found: false } when the Selenium driver has no logs" do
      driver = fake_selenium_driver
      expect(client.send(:detect_websocket_tls_issue, driver)).to eq({ found: false })
    end
  end
end
