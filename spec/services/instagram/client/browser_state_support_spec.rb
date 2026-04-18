require "rails_helper"

RSpec.describe Instagram::Client::BrowserStateSupport do
  # Dispatch is based on the class name of the argument. We fake the class
  # name with Struct.new("Playwright__Page", ...) style so we don't need a
  # running Playwright driver. Any object whose class name starts with
  # "Playwright::" is treated as Playwright; "Selenium::" as Selenium.
  def fake_selenium_driver(**attrs)
    klass = Class.new do
      def self.name
        "Selenium::WebDriver::Driver"
      end
    end
    instance = klass.new
    attrs.each do |method, value|
      instance.define_singleton_method(method) { |*args| value.respond_to?(:call) ? value.call(*args) : value }
    end
    instance
  end

  def fake_playwright_page(**attrs)
    klass = Class.new do
      def self.name
        "Playwright::Page"
      end
    end
    instance = klass.new
    attrs.each do |method, value|
      instance.define_singleton_method(method) { |*args, **kwargs| value.respond_to?(:call) ? value.call(*args, **kwargs) : value }
    end
    instance
  end

  let(:client) do
    account = InstagramAccount.create!(username: "bs_#{SecureRandom.hex(4)}")
    Instagram::Client.new(account: account)
  end

  describe "#logged_out_page?" do
    it "detects the login prompt via page_source on the Selenium path" do
      driver = fake_selenium_driver(page_source: "<html>Create an account or log in to Instagram</html>",
                                    find_elements: [])
      expect(client.send(:logged_out_page?, driver)).to be(true)
    end

    it "detects the username input via find_elements on the Selenium path" do
      username_el = double("WebElement")
      driver = fake_selenium_driver(page_source: "<html>ok</html>",
                                    find_elements: [username_el])
      expect(client.send(:logged_out_page?, driver)).to be(true)
    end

    it "returns false when neither signal is present on the Selenium path" do
      driver = fake_selenium_driver(page_source: "<html>ok</html>", find_elements: [])
      expect(client.send(:logged_out_page?, driver)).to be(false)
    end

    it "detects the login prompt via page.content on the Playwright path" do
      locator = double("Locator", count: 0)
      page = fake_playwright_page(content: "<html>Create an account or log in to Instagram</html>",
                                  locator: locator)
      expect(client.send(:logged_out_page?, page)).to be(true)
    end

    it "detects the username input via page.locator(...).count on the Playwright path" do
      locator = double("Locator", count: 1)
      page = fake_playwright_page(content: "<html>ok</html>", locator: locator)
      expect(client.send(:logged_out_page?, page)).to be(true)
    end

    it "returns false when neither signal is present on the Playwright path" do
      locator = double("Locator", count: 0)
      page = fake_playwright_page(content: "<html>ok</html>", locator: locator)
      expect(client.send(:logged_out_page?, page)).to be(false)
    end
  end

  describe "#js_click" do
    it "calls .click on a Playwright locator-like element without evaluating" do
      page = fake_playwright_page(evaluate: ->(_script, **_) { raise "should not be called" })
      element = double("Locator", click: nil)
      expect(element).to receive(:click).with(timeout: 2_000)

      client.send(:js_click, page, element)
    end

    it "falls back to page.evaluate when the element does not respond to click (Playwright path)" do
      evaluated = false
      page = fake_playwright_page(evaluate: ->(_script, **_) { evaluated = true; true })
      # Fake a JSHandle-ish object without a click method
      element = Object.new

      client.send(:js_click, page, element)
      expect(evaluated).to be(true)
    end

    it "delegates to driver.execute_script on the Selenium path" do
      captured = nil
      driver = fake_selenium_driver(execute_script: ->(script, *_args) { captured = script; true })
      client.send(:js_click, driver, double("WebElement"))
      expect(captured).to include("scrollIntoView")
      expect(captured).to include("el.click()")
    end
  end

  describe "#read_web_storage" do
    it "calls page.evaluate on the Playwright path and returns the array" do
      entries = [{ "key" => "a", "value" => "1" }]
      page = fake_playwright_page(evaluate: ->(_script) { entries })
      expect(client.send(:read_web_storage, page, "localStorage")).to eq(entries)
    end

    it "calls driver.execute_script on the Selenium path" do
      entries = [{ "key" => "a", "value" => "1" }]
      driver = fake_selenium_driver(execute_script: ->(_script) { entries })
      expect(client.send(:read_web_storage, driver, "localStorage")).to eq(entries)
    end

    it "returns [] on both paths when the implementation raises" do
      page = fake_playwright_page(evaluate: ->(_script) { raise "boom" })
      expect(client.send(:read_web_storage, page, "localStorage")).to eq([])

      driver = fake_selenium_driver(execute_script: ->(_script) { raise "boom" })
      expect(client.send(:read_web_storage, driver, "localStorage")).to eq([])
    end
  end

  describe "#write_web_storage" do
    it "passes the sanitized entries to page.evaluate on the Playwright path" do
      captured = nil
      page = fake_playwright_page(evaluate: ->(_script, arg:) { captured = arg; arg.length })

      client.send(:write_web_storage, page, "localStorage", [
        { key: "a", value: "1" },
        { "key" => "b", "value" => "2" },
        { value: "no_key_so_dropped" }
      ])

      expect(captured.map { |e| e["key"] }).to eq(%w[a b])
    end

    it "passes the sanitized entries to driver.execute_script on the Selenium path" do
      captured = nil
      driver = fake_selenium_driver(execute_script: ->(_script, arg) { captured = arg; arg.length })

      client.send(:write_web_storage, driver, "localStorage", [
        { "key" => "a", "value" => "1" }
      ])

      expect(captured).to eq([{ "key" => "a", "value" => "1" }])
    end
  end

  describe "#dismiss_common_overlays!" do
    it "uses get_by_role('button', name: ...) on the Playwright path" do
      calls = []
      button_locator = double("Locator")
      allow(button_locator).to receive(:count).and_return(1)
      allow(button_locator).to receive(:first).and_return(button_locator)
      allow(button_locator).to receive(:click) { |**| calls << "clicked" }

      page = fake_playwright_page(get_by_role: ->(_role, **_) { button_locator })
      allow(page).to receive(:sleep)

      client.send(:dismiss_common_overlays!, page)

      expect(calls.length).to be >= 1 # one click per matching button text
    end

    it "iterates xpath lookups and clicks displayed buttons on the Selenium path" do
      button = double("WebElement", displayed?: true)
      allow(button).to receive(:click)

      driver = fake_selenium_driver(find_elements: [button])
      allow(driver).to receive(:sleep)

      client.send(:dismiss_common_overlays!, driver)

      expect(button).to have_received(:click).at_least(:once)
    end
  end
end
