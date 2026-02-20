module Instagram
  class Client
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
        body = driver.page_source.to_s.downcase
        body.include?("create an account or log in to instagram") ||
          body.include?("\"is_logged_in\":false") ||
          driver.find_elements(css: "input[name='username']").any?
      rescue StandardError
        false
      end

      def dismiss_common_overlays!(driver)
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

      def js_click(driver, element)
        driver.execute_script(<<~JS, element)
          const el = arguments[0];
          if (!el) return false;
          try { el.scrollIntoView({ block: "center", inline: "nearest" }); } catch (e) {}
          try { el.click(); return true; } catch (e) {}
          return false;
        JS
      end

      def read_web_storage(driver, storage_name)
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

      def write_web_storage(driver, storage_name, entries)
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
    end
  end
end
