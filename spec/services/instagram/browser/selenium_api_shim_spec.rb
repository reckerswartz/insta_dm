require "rails_helper"

RSpec.describe Instagram::Browser::SeleniumApiShim do
  # Build a fake Page/Context/Locator/Keyboard so we don't need a real
  # Chromium. The shim's only job is translation; tests verify the shapes.
  def fake_page(**attrs)
    klass = Class.new { def self.name; "Playwright::Page"; end }
    p = klass.new
    attrs.each do |m, v|
      p.define_singleton_method(m) { |*a, **kw| v.respond_to?(:call) ? v.call(*a, **kw) : v }
    end
    p
  end

  def fake_locator(**attrs)
    klass = Class.new { def self.name; "Playwright::Locator"; end }
    l = klass.new
    attrs.each do |m, v|
      l.define_singleton_method(m) { |*a, **kw| v.respond_to?(:call) ? v.call(*a, **kw) : v }
    end
    l
  end

  describe "page-level forwards" do
    it "maps current_url/url/title/page_source/content" do
      page = fake_page(url: "https://x.com/", title: "X", content: "<html>ok</html>")
      shim = described_class.new(page: page)

      expect(shim.current_url).to eq("https://x.com/")
      expect(shim.url).to eq("https://x.com/")
      expect(shim.title).to eq("X")
      expect(shim.page_source).to eq("<html>ok</html>")
      expect(shim.content).to eq("<html>ok</html>")
    end

    it "forwards save_screenshot to page.screenshot(path: ...)" do
      calls = []
      page = fake_page(screenshot: ->(**kw) { calls << kw })
      described_class.new(page: page).save_screenshot("/tmp/ss.png")
      expect(calls.first).to eq({ path: "/tmp/ss.png" })
    end

    it "quit is a no-op (AccountContext owns lifecycle)" do
      expect { described_class.new(page: fake_page).quit }.not_to raise_error
    end
  end

  describe "#navigate" do
    it "maps #to(url) to page.goto" do
      calls = []
      page = fake_page(goto: ->(url) { calls << url })
      described_class.new(page: page).navigate.to("https://x.com/")
      expect(calls).to eq(["https://x.com/"])
    end

    it "maps #refresh to page.reload" do
      reloaded = false
      page = fake_page(reload: ->() { reloaded = true })
      described_class.new(page: page).navigate.refresh
      expect(reloaded).to be(true)
    end
  end

  describe "#execute_script" do
    it "wraps the script in an arrow function with `arguments` as the parameter name, and passes args through as an array" do
      captured_script = nil
      captured_arg = nil
      page = fake_page(evaluate: ->(script, **kw) { captured_script = script; captured_arg = kw[:arg]; nil })

      described_class.new(page: page).execute_script("return arguments[0] + arguments[1];", 10, 32)

      expect(captured_script).to include("(arguments) =>")
      expect(captured_script).to include("return arguments[0] + arguments[1];")
      expect(captured_arg).to eq([10, 32])
    end

    it "unwraps WebElement args through locator.element_handle (Playwright needs ElementHandle in arrays)" do
      handle = Object.new
      locator = fake_locator(element_handle: handle)
      captured_arg = nil
      page = fake_page(evaluate: ->(_script, **kw) { captured_arg = kw[:arg]; nil })
      shim = described_class.new(page: page)

      element = described_class::WebElement.new(locator: locator, page: page)
      shim.execute_script("return arguments[0];", element)

      expect(captured_arg).to eq([handle])
    end
  end

  describe "#find_element / #find_elements" do
    it "find_element(css:) wraps the first locator into a WebElement" do
      inner_locator = fake_locator
      locator = fake_locator(first: inner_locator)
      page = fake_page(locator: ->(_sel) { locator })

      el = described_class.new(page: page).find_element(css: ".foo")
      expect(el).to be_a(described_class::WebElement)
      expect(el.__locator).to eq(inner_locator)
    end

    it "find_element(xpath:) prefixes with xpath= (Playwright selector syntax)" do
      captured = nil
      locator = fake_locator(first: fake_locator)
      page = fake_page(locator: ->(sel) { captured = sel; locator })

      described_class.new(page: page).find_element(xpath: "//button")
      expect(captured).to eq("xpath=//button")
    end

    it "find_elements returns count WebElements, each backed by locator.nth(i)" do
      calls = []
      locator = fake_locator(count: 3, nth: ->(i) { calls << i; fake_locator })
      page = fake_page(locator: locator)

      elements = described_class.new(page: page).find_elements(css: ".foo")
      expect(elements.length).to eq(3)
      expect(elements).to all(be_a(described_class::WebElement))
      expect(calls).to eq([0, 1, 2])
    end

    it "find_elements returns [] when count is 0" do
      locator = fake_locator(count: 0)
      page = fake_page(locator: locator)

      expect(described_class.new(page: page).find_elements(css: ".foo")).to eq([])
    end
  end

  describe "WebElement" do
    it "#click / #text / #get_attribute / #displayed? forward to the underlying locator" do
      calls = []
      locator = fake_locator(
        click:          ->(**_) { calls << :click; true },
        text_content:   "hello",
        get_attribute:  ->(name) { calls << [:attr, name]; "val_of_#{name}" },
        visible?:       true
      )
      el = described_class::WebElement.new(locator: locator, page: fake_page)

      expect(el.click).to be(true)
      expect(el.text).to eq("hello")
      expect(el.attribute("disabled")).to eq("val_of_disabled")
      expect(el.get_attribute("data-x")).to eq("val_of_data-x")
      expect(el.displayed?).to be(true)

      expect(calls).to include(:click, [:attr, "disabled"], [:attr, "data-x"])
    end

    it "#send_keys on a Symbol calls page.keyboard.press with a mapped key name" do
      keyboard_calls = []
      keyboard = Object.new.tap { |o| o.define_singleton_method(:press) { |k| keyboard_calls << [:press, k] } }
      page = fake_page(keyboard: keyboard)
      locator = fake_locator(type: ->(*) { raise "should not type for symbols" })

      described_class::WebElement.new(locator: locator, page: page).send_keys(:enter)
      expect(keyboard_calls).to eq([[:press, "Enter"]])
    end

    it "#send_keys on a String calls locator.type" do
      typed = []
      locator = fake_locator(type: ->(text) { typed << text })
      described_class::WebElement.new(locator: locator, page: fake_page).send_keys("hello world")

      expect(typed).to eq(["hello world"])
    end
  end

  describe "#manage (cookies)" do
    it "all_cookies returns symbol-keyed hashes shaped like Selenium's output" do
      context = double("BrowserContext", cookies: [
        { "name" => "sessionid", "value" => "abc", "domain" => ".instagram.com", "path" => "/", "secure" => true, "httpOnly" => true }
      ])
      shim = described_class.new(page: fake_page, context: context)

      expect(shim.manage.all_cookies.first).to include(name: "sessionid", secure: true, httpOnly: true)
    end

    it "add_cookie fires context.add_cookies with a single-element array" do
      captured = nil
      context = double("BrowserContext")
      allow(context).to receive(:add_cookies) { |arr| captured = arr }

      shim = described_class.new(page: fake_page, context: context)
      shim.manage.add_cookie(name: "x", value: "1", domain: "y.com", http_only: true)

      expect(captured.length).to eq(1)
      expect(captured.first[:name]).to eq("x")
      expect(captured.first[:httpOnly]).to be(true)
    end
  end

  describe "#logs (browser/perf)" do
    it "available_types returns [:browser, :performance] when instrumentation is attached" do
      instrumentation = double("Instr", selenium_shaped_browser_entries: [], selenium_shaped_performance_entries: [])
      page = fake_page
      page.define_singleton_method(:instrumentation) { instrumentation }

      shim = described_class.new(page: page)
      expect(shim.logs.available_types).to eq([:browser, :performance])
    end

    it "get(:browser) returns LogEntry structs forwarded from instrumentation" do
      instrumentation = double("Instr",
                                selenium_shaped_browser_entries: [
                                  { timestamp: 1, level: "WARNING", message: "hi" }
                                ],
                                selenium_shaped_performance_entries: [])
      page = fake_page
      page.define_singleton_method(:instrumentation) { instrumentation }

      entries = described_class.new(page: page).logs.get(:browser)
      expect(entries.length).to eq(1)
      expect(entries.first.timestamp).to eq(1)
      expect(entries.first.level).to eq("WARNING")
      expect(entries.first.message).to eq("hi")
    end

    it "returns [] when no instrumentation is attached" do
      shim = described_class.new(page: fake_page)
      expect(shim.logs.available_types).to eq([])
      expect(shim.logs.get(:browser)).to eq([])
    end
  end

  describe "#action (ActionChains-lite)" do
    it "replays a .click(el).send_keys(:enter).perform chain via Playwright primitives" do
      locator_events = []
      keyboard_events = []
      locator = fake_locator(click: ->(**_) { locator_events << :click })
      keyboard = Object.new.tap { |o| o.define_singleton_method(:press) { |k| keyboard_events << k } }
      page = fake_page(keyboard: keyboard)

      shim = described_class.new(page: page)
      el = described_class::WebElement.new(locator: locator, page: page)
      shim.action.click(el).send_keys(:enter).perform

      expect(locator_events).to eq([:click])
      expect(keyboard_events).to eq(["Enter"])
    end

    it "replays key_down/key_up around send_keys for ctrl+a-then-backspace" do
      kb_down = []; kb_up = []; kb_press = []; kb_type = []
      keyboard = Object.new.tap do |o|
        o.define_singleton_method(:down) { |k| kb_down << k }
        o.define_singleton_method(:up)   { |k| kb_up << k }
        o.define_singleton_method(:press) { |k| kb_press << k }
        o.define_singleton_method(:type)  { |k| kb_type << k }
      end
      page = fake_page(keyboard: keyboard)

      shim = described_class.new(page: page)
      shim.action.send_keys(:enter).perform
      shim.action.key_down(:control).send_keys("a").key_up(:control).send_keys(:backspace).perform

      expect(kb_press).to eq(["Enter", "Backspace"])
      expect(kb_type).to eq(["a"])
      expect(kb_down).to eq(["Control"])
      expect(kb_up).to eq(["Control"])
    end
  end
end
