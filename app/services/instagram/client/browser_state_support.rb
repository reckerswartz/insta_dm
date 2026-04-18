module Instagram
  class Client
    # Small browser-state helpers shared across the Instagram::Client facade.
    # Every public method accepts a `driver` that is either:
    #   * a Selenium::WebDriver (legacy path), or
    #   * a Playwright::Page (Phase 3 port).
    # Dispatch happens per-method via Instagram::Browser::Config.
    module BrowserStateSupport
      private

      def bool(value)
        ActiveModel::Type::Boolean.new.cast(value)
      end

      def normalize_same_site(value)
        token = value.to_s.strip.downcase
        return nil if token.blank?

        case token
        when "lax" then "Lax"
        when "strict" then "Strict"
        when "none", "no_restriction" then "None"
        end
      end

      def logged_out_page?(driver)
        if Instagram::Browser::Config.playwright_driver?(driver)
          logged_out_page_playwright?(driver)
        else
          logged_out_page_selenium?(driver)
        end
      end

      def dismiss_common_overlays!(driver)
        if Instagram::Browser::Config.playwright_driver?(driver)
          dismiss_common_overlays_playwright!(driver)
        else
          dismiss_common_overlays_selenium!(driver)
        end
      end

      def js_click(driver, element)
        if Instagram::Browser::Config.playwright_driver?(driver)
          js_click_playwright(driver, element)
        else
          js_click_selenium(driver, element)
        end
      end

      def read_web_storage(driver, storage_name)
        if Instagram::Browser::Config.playwright_driver?(driver)
          read_web_storage_playwright(driver, storage_name)
        else
          read_web_storage_selenium(driver, storage_name)
        end
      end

      def write_web_storage(driver, storage_name, entries)
        if Instagram::Browser::Config.playwright_driver?(driver)
          write_web_storage_playwright(driver, storage_name, entries)
        else
          write_web_storage_selenium(driver, storage_name, entries)
        end
      end

      # --- Selenium implementations (legacy; removed in Phase 5) -----------

      def logged_out_page_selenium?(driver)
        body = driver.page_source.to_s.downcase
        body.include?("create an account or log in to instagram") ||
          body.include?("\"is_logged_in\":false") ||
          driver.find_elements(css: "input[name='username']").any?
      rescue StandardError
        false
      end

      def dismiss_common_overlays_selenium!(driver)
        # Best-effort: these overlays can prevent story tray elements from being inserted in the DOM.
        dismiss_texts = [
          "Allow all cookies",
          "Accept all",
          "Only allow essential cookies",
          "Not now",
          "Not Now"
        ]

        dismiss_texts.each do |text|
          button = driver.find_elements(xpath: "//button[normalize-space()='#{text}']").first
          next unless button&.displayed?

          button.click
          sleep(0.3)
        rescue StandardError
          next
        end
      end

      def js_click_selenium(driver, element)
        driver.execute_script(<<~JS, element)
          const el = arguments[0];
          if (!el) return false;
          try { el.scrollIntoView({ block: "center", inline: "nearest" }); } catch (e) {}
          try { el.click(); return true; } catch (e) {}
          return false;
        JS
      end

      def read_web_storage_selenium(driver, storage_name)
        script = <<~JS
          const s = window[#{storage_name.inspect}];
          const out = [];
          for (let i = 0; i < s.length; i++) {
            const k = s.key(i);
            out.push({ key: k, value: s.getItem(k) });
          }
          return out;
        JS
        driver.execute_script(script).map { |entry| entry.transform_keys(&:to_s) }
      rescue StandardError
        []
      end

      def write_web_storage_selenium(driver, storage_name, entries)
        safe_entries = Array(entries).map do |entry|
          entry = entry.to_h
          { "key" => entry["key"] || entry[:key], "value" => entry["value"] || entry[:value] }
        end.select { |e| e["key"].present? }

        script = <<~JS
          const s = window[#{storage_name.inspect}];
          const entries = arguments[0] || [];
          for (const e of entries) {
            try { s.setItem(e.key, e.value); } catch (err) {}
          }
          return entries.length;
        JS
        driver.execute_script(script, safe_entries)
      rescue StandardError
        nil
      end

      # --- Playwright implementations (Phase 3 port) -----------------------

      def logged_out_page_playwright?(page)
        body = page.content.to_s.downcase
        return true if body.include?("create an account or log in to instagram")
        return true if body.include?('"is_logged_in":false')

        page.locator("input[name='username']").count.to_i.positive?
      rescue StandardError
        false
      end

      def dismiss_common_overlays_playwright!(page)
        dismiss_texts = [
          "Allow all cookies",
          "Accept all",
          "Only allow essential cookies",
          "Not now",
          "Not Now"
        ]

        dismiss_texts.each do |text|
          # get_by_role with name: picks up buttons by accessible name, which
          # matches Instagram's consent prompts more reliably than xpath text
          # matching. Fall back to xpath if role-based lookup fails.
          begin
            button = page.get_by_role("button", name: text, exact: true)
            next if button.count.to_i.zero?

            button.first.click(timeout: 1_500)
            sleep(0.3)
          rescue StandardError
            begin
              fallback = page.locator("xpath=//button[normalize-space()='#{text}']").first
              next if fallback.nil? || fallback.count.to_i.zero?

              fallback.click(timeout: 1_500)
              sleep(0.3)
            rescue StandardError
              next
            end
          end
        end
      end

      # Playwright locators handle scroll-into-view and click retries
      # natively, so the Selenium "scroll + click + catch" song-and-dance
      # collapses to `.click`. We still defensively handle element handles
      # vs. locators vs. plain elements returned by page.evaluate.
      def js_click_playwright(page, element)
        if element.respond_to?(:click)
          element.click(timeout: 2_000)
          true
        else
          # element is a JSHandle / raw script return -- fall back to an
          # in-page evaluate that mirrors the Selenium behavior.
          page.evaluate(<<~JS, arg: element)
            (el) => {
              if (!el) return false;
              try { el.scrollIntoView({ block: "center", inline: "nearest" }); } catch (e) {}
              try { el.click(); return true; } catch (e) {}
              return false;
            }
          JS
        end
      rescue StandardError
        false
      end

      def read_web_storage_playwright(page, storage_name)
        page.evaluate(<<~JS)
          () => {
            const s = window[#{storage_name.inspect}];
            const out = [];
            for (let i = 0; i < s.length; i++) {
              const k = s.key(i);
              out.push({ key: k, value: s.getItem(k) });
            }
            return out;
          }
        JS
      rescue StandardError
        []
      end

      def write_web_storage_playwright(page, storage_name, entries)
        safe_entries = Array(entries).map do |entry|
          entry = entry.to_h
          { "key" => entry["key"] || entry[:key], "value" => entry["value"] || entry[:value] }
        end.select { |e| e["key"].present? }

        page.evaluate(<<~JS, arg: safe_entries)
          (entries) => {
            const s = window[#{storage_name.inspect}];
            const list = entries || [];
            for (const e of list) {
              try { s.setItem(e.key, e.value); } catch (err) {}
            }
            return list.length;
          }
        JS
      rescue StandardError
        nil
      end
    end
  end
end
