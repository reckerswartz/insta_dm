module Instagram
  module Browser
    # Exposes a subset of the Selenium::WebDriver API on top of a
    # Playwright::Page. Phase 3 steps 6-11 port the large support modules
    # by wrapping the Playwright page with this shim so the existing
    # Selenium-shaped code keeps working without per-method dispatch.
    #
    # This shim is temporary. Phase 5 either:
    #   * rewrites the remaining modules to call Playwright APIs directly
    #     and removes this class, or
    #   * leaves the shim as a permanent translation layer and only
    #     deletes selenium-webdriver + the *_selenium branches.
    #
    # The shim intentionally does NOT claim to be a complete Selenium
    # implementation. Only the surface actually exercised by the existing
    # facade is implemented. Anything else raises NotImplementedError so
    # we notice during tests rather than silently regressing behavior.
    class SeleniumApiShim
      # The shim is NOT under the Playwright:: namespace, so
      # Instagram::Browser::Config.playwright_driver?(shim) returns false.
      # This is deliberate: existing support modules with per-method
      # dispatch (BrowserStateSupport, CoreHelpers, TaskCaptureSupport)
      # will route the shim through the Selenium code path, which calls
      # methods on the shim that forward to Playwright. The net effect
      # is that the shim looks like a Selenium driver to all facade code.

      attr_reader :page, :context

      def initialize(page:, context: nil)
        @page = page
        @context = context
        @manage = Manage.new(page, context)
        @navigate = Navigate.new(page)
        @logs = Logs.new(page)
      end

      # ---- Page-level -----------------------------------------------------

      def current_url
        @page.url
      end

      def url
        @page.url
      end

      def title
        @page.title
      end

      def page_source
        @page.content
      end

      def content
        @page.content
      end

      def save_screenshot(path)
        @page.screenshot(path: path.to_s)
        path.to_s
      end

      def screenshot(path: nil)
        if path
          @page.screenshot(path: path.to_s)
          path.to_s
        else
          @page.screenshot
        end
      end

      def quit
        # AccountContext owns the persistent context lifecycle; this is a
        # no-op to match Selenium's teardown contract so existing `ensure`
        # blocks don't double-close.
        nil
      end

      def close
        # Same as quit on the Playwright path; context close is handled
        # by AccountContext#with_context.
        nil
      end

      def manage
        @manage
      end

      def navigate
        @navigate
      end

      def logs
        @logs
      end

      def action
        ActionChain.new(@page)
      end

      # Runs `block` and re-raises Playwright errors as the closest
      # Selenium equivalents. This keeps existing rescue clauses in the
      # facade (rescue Selenium::WebDriver::Error::TimeoutError, ...) working
      # after the shim swap. Unknown Playwright errors pass through as-is.
      def self.translate_playwright_error
        yield
      rescue Playwright::TimeoutError => e
        raise Selenium::WebDriver::Error::TimeoutError, e.message
      rescue Playwright::Error => e
        msg = e.message.to_s.downcase
        case msg
        when /element is not visible/, /is not attached to the dom/, /element was hidden/
          raise Selenium::WebDriver::Error::StaleElementReferenceError, e.message
        when /no element found/, /no elements match/, /strict mode violation/
          raise Selenium::WebDriver::Error::NoSuchElementError, e.message
        when /click intercepted/, /intercepts pointer events/
          raise Selenium::WebDriver::Error::ElementClickInterceptedError, e.message
        when /element is disabled/, /is not editable/, /element is not enabled/
          raise Selenium::WebDriver::Error::InvalidElementStateError, e.message
        when /element is not receiving pointer events/, /is outside of the viewport/
          raise Selenium::WebDriver::Error::ElementNotInteractableError, e.message
        else
          raise
        end
      end

      # ---- JavaScript execution ------------------------------------------

      # Selenium: execute_script("return arguments[0] + arguments[1]", a, b)
      # Playwright: page.evaluate("(arguments) => { return arguments[0] + arguments[1] }", arg: [a, b])
      #
      # Wraps the script body in an arrow function whose single parameter
      # is named `arguments`, so existing `arguments[N]` references in
      # Selenium-era scripts work unchanged.
      def execute_script(script, *args)
        wrapped = "(arguments) => {\n#{script}\n}"
        self.class.translate_playwright_error do
          @page.evaluate(wrapped, arg: normalize_script_args(args))
        end
      end

      # Selenium supports execute_async_script: the script receives a
      # callback as the last arg and calls it when async work completes.
      # Playwright's evaluate awaits Promises directly, so we translate
      # by providing a Promise-resolving callback.
      def execute_async_script(script, *args)
        wrapped = <<~JS
          (arguments) => new Promise((resolve) => {
            const originalArgs = arguments;
            const argsWithCallback = originalArgs.concat([resolve]);
            (function(arguments) {
              #{script}
            })(argsWithCallback);
          })
        JS
        @page.evaluate(wrapped, arg: normalize_script_args(args))
      end

      # ---- Element lookup ------------------------------------------------

      # Selenium's find_element(css: ".foo") / find_element(xpath: "//a").
      # Returns a single element (raising if not found, like Selenium does).
      # Playwright equivalent: page.locator(sel).first -- but we defer the
      # locator to the time click/text/etc. is called so stale elements
      # are auto-retried.
      def find_element(css: nil, xpath: nil)
        selector = to_playwright_selector(css: css, xpath: xpath)
        locator = @page.locator(selector).first
        WebElement.new(locator: locator, page: @page)
      end

      # Selenium's find_elements returns [] when nothing matches.
      # Playwright's page.locator(sel).count gives us the live count.
      # We return an array of WebElement shims indexed into .nth(i).
      def find_elements(css: nil, xpath: nil)
        selector = to_playwright_selector(css: css, xpath: xpath)
        locator = @page.locator(selector)
        count = safe_int(locator.count)
        return [] if count.zero?

        Array.new(count) { |i| WebElement.new(locator: locator.nth(i), page: @page) }
      rescue StandardError
        []
      end

      # Callers occasionally use driver.call(...) to reach facade methods
      # via method objects. No translation needed; the shim just forwards
      # to Ruby's default method_missing behavior if something calls
      # `driver.call` expecting the Selenium driver to be callable.
      def respond_to_missing?(name, include_private = false)
        @page.respond_to?(name, include_private) || super
      end

      def method_missing(name, *args, **kwargs, &block)
        return @page.send(name, *args, **kwargs, &block) if @page.respond_to?(name)

        raise NotImplementedError,
              "SeleniumApiShim does not implement ##{name}. " \
              "Either add it to the shim or port the caller to Playwright APIs directly."
      end

      private

      def to_playwright_selector(css:, xpath:)
        return css if css
        return "xpath=#{xpath}" if xpath

        raise ArgumentError, "find_element(s) requires css: or xpath:"
      end

      def safe_int(value)
        Integer(value)
      rescue StandardError
        0
      end

      # Unwrap WebElement shims so scripts see raw DOM elements.
      # Playwright requires ElementHandle (not Locator) when the element is
      # nested inside an array arg, so we resolve locator.element_handle()
      # for each WebElement. For a bare WebElement argument Playwright would
      # accept the Locator directly, but going through element_handle is
      # uniformly correct and cheap.
      def normalize_script_args(args)
        args.map do |a|
          case a
          when WebElement then a.__locator.element_handle
          else a
          end
        end
      end

      # ------------ nested shim classes ----------------------------------

      class WebElement
        attr_reader :__locator

        def initialize(locator:, page:)
          @__locator = locator
          @page = page
        end

        def click
          SeleniumApiShim.translate_playwright_error do
            @__locator.click(timeout: 5_000)
            true
          end
        end

        def send_keys(*keys)
          SeleniumApiShim.translate_playwright_error do
            keys.flatten.each do |key|
              case key
              when Symbol
                @page.keyboard.press(symbol_to_key(key))
              else
                @__locator.type(key.to_s)
              end
            end
            true
          end
        end

        def text
          @__locator.text_content.to_s
        rescue StandardError
          ""
        end

        def attribute(name)
          get_attribute(name)
        end

        def get_attribute(name)
          @__locator.get_attribute(name.to_s)
        rescue StandardError
          nil
        end

        def displayed?
          @__locator.visible?
        rescue StandardError
          false
        end

        def enabled?
          result = @__locator.evaluate("(el) => !('disabled' in el) || !el.disabled")
          !!result
        rescue StandardError
          true
        end

        def tag_name
          @__locator.evaluate("(el) => (el.tagName || '').toLowerCase()").to_s
        rescue StandardError
          ""
        end

        def find_element(css: nil, xpath: nil)
          selector = css || (xpath && "xpath=#{xpath}")
          raise ArgumentError, "find_element requires css: or xpath:" unless selector

          nested = @__locator.locator(selector).first
          self.class.new(locator: nested, page: @page)
        end

        def find_elements(css: nil, xpath: nil)
          selector = css || (xpath && "xpath=#{xpath}")
          return [] unless selector

          nested = @__locator.locator(selector)
          count = Integer(nested.count) rescue 0
          Array.new(count) { |i| self.class.new(locator: nested.nth(i), page: @page) }
        rescue StandardError
          []
        end

        def ==(other)
          other.is_a?(WebElement) && other.__locator == @__locator
        end

        private

        def symbol_to_key(sym)
          {
            enter: "Enter",
            return: "Enter",
            tab: "Tab",
            escape: "Escape",
            esc: "Escape",
            backspace: "Backspace",
            delete: "Delete",
            space: "Space",
            control: "Control",
            ctrl: "Control",
            shift: "Shift",
            alt: "Alt",
            meta: "Meta",
            up: "ArrowUp",
            down: "ArrowDown",
            left: "ArrowLeft",
            right: "ArrowRight",
            home: "Home",
            end: "End"
          }.fetch(sym, sym.to_s.capitalize)
        end
      end

      class Navigate
        def initialize(page)
          @page = page
        end

        def to(url)
          @page.goto(url.to_s)
        end

        def refresh
          @page.reload
        end

        def back
          @page.go_back
        end

        def forward
          @page.go_forward
        end
      end

      class Manage
        def initialize(page, context)
          @page = page
          @context = context
        end

        def all_cookies
          cookies = context_cookies
          cookies.map do |c|
            # Return symbol-keyed hashes matching Selenium's driver.manage.all_cookies shape.
            {
              name: c[:name] || c["name"],
              value: c[:value] || c["value"],
              domain: c[:domain] || c["domain"],
              path: c[:path] || c["path"],
              expires: c[:expires] || c["expires"],
              secure: c[:secure] || c["secure"] || false,
              httpOnly: c[:httpOnly] || c["httpOnly"] || false
            }
          end
        rescue StandardError
          []
        end

        def add_cookie(cookie)
          return unless @context

          cookie_hash = cookie.respond_to?(:to_h) ? cookie.to_h : cookie
          normalized = cookie_hash.transform_keys(&:to_sym)

          # Selenium's add_cookie is single-cookie; Playwright's add_cookies is array.
          @context.add_cookies([
                                 {
                                   name: normalized[:name],
                                   value: normalized[:value],
                                   domain: normalized[:domain],
                                   path: normalized[:path] || "/",
                                   expires: normalized[:expires] || -1,
                                   httpOnly: normalized[:http_only] || normalized[:httpOnly] || false,
                                   secure: normalized[:secure] || false,
                                   sameSite: (normalized[:same_site] || normalized[:sameSite] || "Lax").to_s.capitalize
                                 }.compact
                               ])
        end

        def delete_all_cookies
          @context&.clear_cookies
        end

        private

        def context_cookies
          return [] unless @context

          @context.cookies
        end
      end

      class Logs
        def initialize(page)
          @page = page
        end

        def available_types
          return [] unless instrumentation

          [:browser, :performance]
        end

        def get(kind)
          return [] unless instrumentation

          case kind
          when :browser, "browser"
            instrumentation.selenium_shaped_browser_entries.map do |e|
              LogEntry.new(e[:timestamp], e[:level], e[:message])
            end
          when :performance, "performance"
            instrumentation.selenium_shaped_performance_entries.map do |e|
              LogEntry.new(e["timestamp"], "INFO", e["message"])
            end
          else
            []
          end
        end

        private

        def instrumentation
          @page.respond_to?(:instrumentation) ? @page.instrumentation : nil
        end

        LogEntry = Struct.new(:timestamp, :level, :message)
      end

      # Minimal ActionChains shim. The Instagram facade uses these shapes:
      #   driver.action.move_to(el).click.perform
      #   driver.action.click(field).send_keys(:enter).perform
      #   driver.action.click(box).key_down(:control).send_keys("a").key_up(:control).send_keys(:backspace).perform
      #   driver.action.click(box).send_keys(text).perform
      #   driver.action.send_keys(:enter).perform
      #   driver.action.send_keys(text).perform
      class ActionChain
        def initialize(page)
          @page = page
          @queue = []
        end

        def move_to(el)
          @queue << [:hover, el]
          self
        end

        def click(el = nil)
          @queue << [:click, el]
          self
        end

        def send_keys(*keys)
          @queue << [:send_keys, keys.flatten]
          self
        end

        def key_down(key)
          @queue << [:key_down, key]
          self
        end

        def key_up(key)
          @queue << [:key_up, key]
          self
        end

        def perform
          @queue.each do |(op, arg)|
            case op
            when :hover
              element_ref(arg)&.__locator&.hover
            when :click
              if arg
                element_ref(arg)&.__locator&.click
              else
                # Selenium action.click() with no target is "click at current pointer" --
                # rarely used; Playwright has no exact equivalent, so treat as Enter press.
                @page.keyboard.press("Enter")
              end
            when :send_keys
              arg.each do |k|
                if k.is_a?(Symbol)
                  @page.keyboard.press(symbol_to_key(k))
                else
                  @page.keyboard.type(k.to_s)
                end
              end
            when :key_down
              @page.keyboard.down(symbol_to_key(arg))
            when :key_up
              @page.keyboard.up(symbol_to_key(arg))
            end
          end
        ensure
          @queue.clear
        end

        private

        def element_ref(arg)
          arg.is_a?(WebElement) ? arg : nil
        end

        def symbol_to_key(sym)
          {
            enter: "Enter",
            return: "Enter",
            tab: "Tab",
            escape: "Escape",
            esc: "Escape",
            backspace: "Backspace",
            delete: "Delete",
            space: "Space",
            control: "Control",
            ctrl: "Control",
            shift: "Shift",
            alt: "Alt",
            meta: "Meta",
            up: "ArrowUp",
            down: "ArrowDown",
            left: "ArrowLeft",
            right: "ArrowRight"
          }.fetch(sym, sym.to_s.capitalize)
        end
      end
    end
  end
end
