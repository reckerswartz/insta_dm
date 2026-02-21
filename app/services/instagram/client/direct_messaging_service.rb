module Instagram
  class Client
    module DirectMessagingService
    def send_messages!(usernames:, message_text:)
      BulkMessageSendService.new(
        with_recoverable_session: method(:with_recoverable_session),
        with_authenticated_driver: method(:with_authenticated_driver),
        find_profile_for_interaction: method(:find_profile_for_interaction),
        dm_interaction_retry_pending: method(:dm_interaction_retry_pending?),
        send_direct_message_via_api: method(:send_direct_message_via_api!),
        mark_profile_dm_state: method(:mark_profile_dm_state!),
        apply_dm_state_from_send_result: method(:apply_dm_state_from_send_result),
        disconnected_session_error: method(:disconnected_session_error?),
        open_dm: method(:open_dm),
        send_text_message_from_driver: method(:send_text_message_from_driver!)
      ).call(usernames: usernames, message_text: message_text)
    end

    def send_message_to_user!(username:, message_text:)
      SingleMessageSendService.new(
        with_recoverable_session: method(:with_recoverable_session),
        with_authenticated_driver: method(:with_authenticated_driver),
        with_task_capture: method(:with_task_capture),
        find_profile_for_interaction: method(:find_profile_for_interaction),
        dm_interaction_retry_pending: method(:dm_interaction_retry_pending?),
        send_direct_message_via_api: method(:send_direct_message_via_api!),
        mark_profile_dm_state: method(:mark_profile_dm_state!),
        apply_dm_state_from_send_result: method(:apply_dm_state_from_send_result),
        open_dm: method(:open_dm),
        send_text_message_from_driver: method(:send_text_message_from_driver!)
      ).call(username: username, message_text: message_text)
    end

    def send_direct_message_via_api!(username:, message_text:)
      text = message_text.to_s.strip
      return { sent: false, method: "api", reason: "blank_message_text" } if text.blank?

      uname = normalize_username(username)
      return { sent: false, method: "api", reason: "blank_username" } if uname.blank?

      user_id = story_user_id_for(username: uname)
      return { sent: false, method: "api", reason: "missing_user_id" } if user_id.blank?

      thread_id = direct_thread_id_for_user(user_id: user_id)
      return { sent: false, method: "api", reason: "missing_thread_id" } if thread_id.blank?

      body = ig_api_post_form_json(
        path: "/api/v1/direct_v2/threads/broadcast/text/",
        referer: "#{INSTAGRAM_BASE_URL}/direct/t/#{thread_id}/",
        form: {
          action: "send_item",
          client_context: story_api_client_context,
          thread_id: thread_id,
          text: text
        }
      )
      return { sent: false, method: "api", reason: "empty_api_response" } unless body.is_a?(Hash)

      status = body["status"].to_s
      if status == "ok"
        return {
          sent: true,
          method: "api",
          reason: "text_sent",
          api_status: status,
          api_thread_id: body.dig("payload", "thread_id").to_s.presence || thread_id,
          api_item_id: body.dig("payload", "item_id").to_s.presence
        }
      end

      {
        sent: false,
        method: "api",
        reason: body["message"].to_s.presence || body.dig("payload", "message").to_s.presence || body["error_type"].to_s.presence || "api_status_#{status.presence || 'unknown'}",
        api_status: status.presence || "unknown",
        api_http_status: body["_http_status"],
        api_error_code: body.dig("payload", "error_code").to_s.presence || body["error_code"].to_s.presence
      }
    rescue StandardError => e
      { sent: false, method: "api", reason: "api_exception:#{e.class.name}" }
    end

    def verify_messageability!(username:)
      with_recoverable_session(label: "verify_messageability") do
        result = verify_messageability_from_api(username: username)
        return result if !result.is_a?(Hash) || !result[:can_message].nil?

        with_authenticated_driver do |driver|
          verify_messageability_from_driver(driver, username: username)
        end
      end
    end

    def verify_messageability_from_api(username:)
      uname = normalize_username(username)
      return { can_message: nil, restriction_reason: "Username is blank", source: "api" } if uname.blank?

      user_id = story_user_id_for(username: uname)
      if user_id.blank?
        return {
          can_message: false,
          restriction_reason: "Unable to resolve user id via API",
          source: "api",
          dm_state: "unknown",
          dm_reason: "missing_user_id",
          dm_retry_after_at: Time.current + 6.hours
        }
      end

      thread_result = create_direct_thread_for_user(user_id: user_id, use_cache: false)
      thread_id = thread_result[:thread_id].to_s
      return { can_message: true, restriction_reason: nil, source: "api", dm_state: "messageable", dm_reason: "thread_created", dm_retry_after_at: nil } if thread_id.present?

      reason = thread_result[:reason].to_s.presence || "missing_thread_id"
      retry_after =
        if thread_result[:api_http_status].to_i == 403
          Time.current + STORY_INTERACTION_RETRY_DAYS.days
        else
          Time.current + 12.hours
        end

      {
        can_message: false,
        restriction_reason: "DM unavailable via API (#{reason})",
        source: "api",
        dm_state: "unavailable",
        dm_reason: reason,
        dm_retry_after_at: retry_after,
        api_status: thread_result[:api_status],
        api_http_status: thread_result[:api_http_status],
        api_error_code: thread_result[:api_error_code]
      }
    rescue StandardError => e
      {
        can_message: nil,
        restriction_reason: "Unable to verify messaging availability (api exception)",
        source: "api",
        dm_state: "unknown",
        dm_reason: "exception:#{e.class.name}",
        dm_retry_after_at: Time.current + 6.hours
      }
    end

    def verify_messageability_from_driver(driver, username:)
      username = normalize_username(username)
      raise "Username cannot be blank" if username.blank?

      with_task_capture(driver: driver, task_name: "profile_verify_messageability", meta: { username: username }) do
        ok = open_dm(driver, username)
        if !ok
          {
            can_message: false,
            restriction_reason: "Unable to open DM thread",
            source: "ui",
            dm_state: "unavailable",
            dm_reason: "unable_to_open_dm_thread",
            dm_retry_after_at: Time.current + 12.hours
          }
        else
          begin
            wait_for_present(driver, css: dm_textbox_css, timeout: 10)
            {
              can_message: true,
              restriction_reason: nil,
              source: "ui",
              dm_state: "messageable",
              dm_reason: "composer_visible",
              dm_retry_after_at: nil
            }
          rescue Selenium::WebDriver::Error::TimeoutError
            {
              can_message: false,
              restriction_reason: "Unable to open message box",
              source: "ui",
              dm_state: "unavailable",
              dm_reason: "message_box_unavailable",
              dm_retry_after_at: Time.current + 12.hours
            }
          end
        end
      end
    end

    def open_dm_from_profile(driver, username)
      driver.navigate.to("#{INSTAGRAM_BASE_URL}/#{username}/")
      wait_for(driver, css: "body", timeout: 10)
      dismiss_common_overlays!(driver)
      human_pause

      # Case-insensitive contains("message") across common clickable elements.
      ci = "translate(normalize-space(.), 'ABCDEFGHIJKLMNOPQRSTUVWXYZ', 'abcdefghijklmnopqrstuvwxyz')"
      message_xpath = "//*[self::button or (self::div and @role='button') or self::a][contains(#{ci}, 'message')]"
      aria_xpath = "//*[@aria-label and contains(translate(@aria-label,'ABCDEFGHIJKLMNOPQRSTUVWXYZ','abcdefghijklmnopqrstuvwxyz'),'message')]"

      # Wait for the CTA to be visible. Profile pages often render in stages; grabbing `.first` can pick a hidden node.
      message_button =
        begin
          wait_for(driver, xpath: message_xpath, timeout: 10)
        rescue Selenium::WebDriver::Error::TimeoutError
          nil
        end
      message_button ||= driver.find_elements(xpath: aria_xpath).find { |el| el.displayed? rescue false }

      return false unless message_button

      click_ok =
        begin
          driver.action.move_to(message_button).click.perform
          true
        rescue StandardError
          js_click(driver, message_button)
        end

      return false unless click_ok
      maybe_capture_filmstrip(driver, label: "dm_open_profile_after_click")

      true
    end

    def open_dm(driver, username)
      username = normalize_username(username)
      return false if username.blank?

      # Strategy 1: profile page CTA
      ok = with_task_capture(driver: driver, task_name: "dm_open_profile", meta: { username: username }) do
        open_dm_from_profile(driver, username)
      end
      if ok
        begin
          wait_for_dm_composer_or_thread!(driver, timeout: 12)
          return true
        rescue Selenium::WebDriver::Error::TimeoutError
          # fall through to next strategy
        end
      end

      # Strategy 2: direct/new flow (SPA-safe)
      ok2 = with_task_capture(driver: driver, task_name: "dm_open_direct_new", meta: { username: username }) do
        open_dm_via_direct_new(driver, username)
      end
      return true if ok2

      # On some IG builds the URL flips to the thread before the composer becomes queryable.
      driver.current_url.to_s.include?("/direct/t/")
    end

    def open_dm_via_direct_new(driver, username)
      driver.navigate.to("#{INSTAGRAM_BASE_URL}/direct/new/")
      wait_for(driver, css: "body", timeout: 12)
      dismiss_common_overlays!(driver)
      human_pause

      # Find a search box for recipients.
      selectors = [
        "input[name='queryBox']",
        "input[placeholder*='Search']",
        "input[aria-label*='Search']",
        "input[type='text']"
      ]

      typed = false
      3.times do |attempt|
        input =
          selectors.lazy.map { |sel| driver.find_elements(css: sel).find(&:displayed?) }.find(&:present?) ||
          selectors.lazy.map { |sel| driver.find_elements(css: sel).first }.find(&:present?)

        break unless input

        begin
          input.click
          # Clear any existing value.
          input.send_keys([:control, "a"])
          input.send_keys(:backspace)
          input.send_keys(username)
          typed = true
          human_pause
          break
        rescue Selenium::WebDriver::Error::StaleElementReferenceError, Selenium::WebDriver::Error::ElementNotInteractableError
          Rails.logger.info("open_dm_via_direct_new retry typing (attempt #{attempt + 1}/3)")
          sleep(0.5)
          next
        end
      end

      return false unless typed
      capture_task_html(driver: driver, task_name: "dm_open_direct_new_after_type", status: "ok", meta: { username: username })

      # Wait for the username to appear in results and click it.
      username_down = username.to_s.downcase
      ci = "translate(normalize-space(.), 'ABCDEFGHIJKLMNOPQRSTUVWXYZ', 'abcdefghijklmnopqrstuvwxyz')"
      row_xpath = "//div[@role='button'][.//*[contains(#{ci}, '#{username_down}')]]"
      row_with_img_xpath = "//div[@role='button'][.//*[contains(#{ci}, '#{username_down}')]]//img/ancestor::div[@role='button'][1]"

      begin
        Selenium::WebDriver::Wait.new(timeout: 12).until do
          driver.find_elements(xpath: row_with_img_xpath).any? ||
            driver.find_elements(xpath: row_xpath).any? ||
            driver.find_elements(xpath: "//*[contains(#{ci}, '#{username_down}')]").any?
        end
      rescue Selenium::WebDriver::Error::TimeoutError
        return false
      end

      candidate =
        driver.find_elements(xpath: row_with_img_xpath).find { |el| el.displayed? rescue false } ||
        driver.find_elements(xpath: row_xpath).find { |el| el.displayed? rescue false } ||
        driver.find_elements(xpath: row_xpath).first ||
        driver.find_elements(xpath: "//*[contains(#{ci}, '#{username_down}')]").find { |el| el.displayed? rescue false } ||
        driver.find_elements(xpath: "//*[contains(#{ci}, '#{username_down}')]").first
      return false unless candidate

      # Click nearest clickable container; otherwise click the text node parent.
      clickable =
        begin
          driver.execute_script(<<~JS, candidate)
            const el = arguments[0];
            // For direct/new, the row itself is usually role=button.
            if (el && el.getAttribute && el.getAttribute("role") === "button") return el;
            const btn = el.closest("button,[role='button']");
            return btn || el;
          JS
        rescue StandardError
          candidate
        end

      begin
        driver.action.move_to(clickable).click.perform
      rescue StandardError
        js_click(driver, clickable)
      end
      human_pause
      capture_task_html(driver: driver, task_name: "dm_open_direct_new_after_pick", status: "ok", meta: { username: username })

      # Click the continuation CTA to open chat ("Next" on some builds, "Chat" on others).
      continue_btn = nil
      begin
        Selenium::WebDriver::Wait.new(timeout: 12).until do
          continue_btn =
            driver.find_elements(xpath: "//*[self::button or (self::div and @role='button')][normalize-space()='Next']").find(&:displayed?) ||
            driver.find_elements(xpath: "//*[self::button or (self::div and @role='button')][normalize-space()='Chat']").find(&:displayed?) ||
            driver.find_elements(xpath: "//*[self::button or (self::div and @role='button')][contains(translate(normalize-space(.),'ABCDEFGHIJKLMNOPQRSTUVWXYZ','abcdefghijklmnopqrstuvwxyz'),'next')]").find(&:displayed?) ||
            driver.find_elements(xpath: "//*[self::button or (self::div and @role='button')][contains(translate(normalize-space(.),'ABCDEFGHIJKLMNOPQRSTUVWXYZ','abcdefghijklmnopqrstuvwxyz'),'chat')]").find(&:displayed?)
          continue_btn.present? && element_enabled?(continue_btn)
        end
      rescue Selenium::WebDriver::Error::TimeoutError
        continue_btn = nil
      end

      # Some UI variants jump directly into the thread immediately after recipient selection.
      return true if driver.current_url.to_s.include?("/direct/t/")
      return false unless continue_btn

      begin
        driver.action.move_to(continue_btn).click.perform
      rescue StandardError
        js_click(driver, continue_btn)
      end
      maybe_capture_filmstrip(driver, label: "dm_open_direct_new_after_next")
      capture_task_html(driver: driver, task_name: "dm_open_direct_new_after_next", status: "ok", meta: { username: username })

      wait_for_dm_composer_or_thread!(driver, timeout: 16)
      true
    rescue Selenium::WebDriver::Error::TimeoutError
      false
    end

    def wait_for_dm_composer_or_thread!(driver, timeout:)
      Selenium::WebDriver::Wait.new(timeout: timeout).until do
        url = driver.current_url.to_s
        # Some failures bounce back to inbox; treat as not-opened.
        next false if url.include?("/direct/inbox")

        url.include?("/direct/t/") || driver.find_elements(css: "div[role='textbox']").any?
      end
    end

    def dm_textbox_css
      # The DM composer is a contenteditable div (Lexical editor). On some builds there can be multiple
      # role=textbox nodes (hidden + visible), so we prefer the visible contenteditable one.
      "div[role='textbox'][contenteditable='true'], div[role='textbox']"
    end

	    def send_text_message_from_driver!(driver, message_text, expected_username: nil)
	      raise "Message cannot be blank" if message_text.to_s.strip.blank?

      css = dm_textbox_css
      wait_for_present(driver, css: css, timeout: 12)

      box = find_visible_dm_textbox(driver)
      raise Selenium::WebDriver::Error::NoSuchElementError, "No DM textbox found" unless box

      3.times do |attempt|
        begin
          driver.execute_script("arguments[0].scrollIntoView({block: 'center', inline: 'nearest'});", box)
          driver.execute_script("arguments[0].focus();", box)
          driver.execute_script("arguments[0].click();", box)
        rescue StandardError
          # best effort
        end

        begin
          box.click
        rescue Selenium::WebDriver::Error::ElementClickInterceptedError, Selenium::WebDriver::Error::ElementNotInteractableError
          # ignore; we'll try typing via actions as a fallback
        end

        begin
          # Clear any residual draft text (best effort).
          begin
            driver.action.click(box).key_down(:control).send_keys("a").key_up(:control).send_keys(:backspace).perform
          rescue StandardError
            nil
          end

          # Type using actions (more reliable on IG's Lexical composer than direct send_keys on the element).
          driver.action.click(box).send_keys(message_text.to_s).perform

	          typed = read_dm_textbox_text(driver)
	          capture_task_html(
	            driver: driver,
	            task_name: "dm_send_text_after_type",
	            status: "ok",
	            meta: { expected_username: expected_username, message_preview: message_text.to_s.strip.byteslice(0, 80), textbox_text_preview: typed.to_s.byteslice(0, 120) }
	          )

            # Prefer clicking "Send" first. Recent IG builds sometimes clear the composer on Enter even when
            # the message never actually sends (silent failure), so Enter-first can give a false sense of success.
	          clicked_send = click_dm_send_button(driver, textbox: box)
	          capture_task_html(
	            driver: driver,
	            task_name: "dm_send_text_after_send_click",
	            status: "ok",
	            meta: { expected_username: expected_username, message_preview: message_text.to_s.strip.byteslice(0, 80), clicked_send: clicked_send }
	          )

	          # If we could not click the Send button, attempt Enter as a fallback.
	          enter_attempted = false
	          if !(clicked_send.is_a?(Hash) && clicked_send[:clicked])
	            begin
	              box.send_keys(:enter)
	              enter_attempted = true
	            rescue StandardError
	              enter_attempted = false
	            end
	          end

	          after_enter_text = read_dm_textbox_text(driver)
	          capture_task_html(
	            driver: driver,
	            task_name: "dm_send_text_after_enter",
	            status: "ok",
	            meta: {
	              expected_username: expected_username,
	              message_preview: message_text.to_s.strip.byteslice(0, 80),
	              enter_attempted: enter_attempted,
	              textbox_text_preview: after_enter_text.to_s.byteslice(0, 120),
	              send_button_clicked: (clicked_send.is_a?(Hash) ? clicked_send[:clicked] : nil),
	              send_button_reason: (clicked_send.is_a?(Hash) ? clicked_send[:reason] : nil)
	            }
	          )

	          sent = (clicked_send.is_a?(Hash) ? clicked_send[:clicked] : !!clicked_send) || enter_attempted

	          unless sent
	            # Last resort.
	            driver.action.send_keys(:enter).perform
	          end
          break
        rescue Selenium::WebDriver::Error::StaleElementReferenceError
          sleep(0.4)
          box = find_visible_dm_textbox(driver)
          next
	        rescue Selenium::WebDriver::Error::ElementNotInteractableError, Selenium::WebDriver::Error::InvalidElementStateError
	          # Fallback: send keys to the active element (Instagram's Lexical editor usually focuses it).
	          driver.action.send_keys(message_text.to_s).perform
	          tb = find_visible_dm_textbox(driver)
	          click_dm_send_button(driver, textbox: tb).to_h[:clicked] || driver.action.send_keys(:enter).perform
	          break
	        rescue StandardError
	          raise if attempt >= 2
	          sleep(0.6)
	          next
        end
      end

      verify = verify_dm_send(driver, message_text.to_s, expected_username: expected_username)
      return true if verify[:ok]
      if verify[:reason].to_s.start_with?("websocket_tls_error")
        raise websocket_tls_guidance(verify)
      end

      # Force a debug capture even though the caller will also capture on error.
      capture_task_html(driver: driver, task_name: "dm_send_text_verify", status: "error", meta: verify)
      raise "Message not confirmed as sent (#{verify[:reason]})"
    end

    def find_visible_dm_textbox(driver)
      candidates = driver.find_elements(css: "div[role='textbox'][contenteditable='true']")
      candidates = driver.find_elements(css: "div[role='textbox']") if candidates.empty?

      candidates.find do |el|
        begin
          el.displayed?
        rescue Selenium::WebDriver::Error::StaleElementReferenceError
          false
        end
      end || candidates.first
    end

    def read_dm_textbox_text(driver)
      driver.execute_script(<<~JS)
        const textbox =
          document.querySelector("div[role='textbox'][contenteditable='true']") ||
          document.querySelector("div[role='textbox']");
        if (!textbox) return null;
        return (textbox.innerText || "").toString();
      JS
    rescue StandardError
      nil
    end

	    def verify_dm_send(driver, message_text, expected_username: nil)
	      needle = message_text.to_s.strip
	      return { ok: false, reason: "blank message_text" } if needle.blank?

      # Poll briefly because the UI can take a moment to append the outgoing bubble.
      last = nil
      40.times do |i|
	        # Try to keep the message list near the bottom so the newest outgoing bubble is mounted.
	        begin
	          driver.execute_script(<<~JS)
            const main =
              document.querySelector("div[role='main']") ||
              document.scrollingElement ||
              document.documentElement ||
              document.body;
            try { main.scrollTop = 1e9; } catch (e) {}
            try { window.scrollTo(0, document.body.scrollHeight); } catch (e) {}
          JS
        rescue StandardError
          nil
        end

	        last = driver.execute_script(<<~JS, needle, expected_username.to_s)
	          const needle = (arguments[0] || "").replace(/\\s+/g, " ").trim();
	          const expected = (arguments[1] || "").toLowerCase().trim();

          const norm = (s) => (s || "").replace(/\\s+/g, " ").trim();

          const textbox =
            document.querySelector("div[role='textbox'][contenteditable='true']") ||
            document.querySelector("div[role='textbox']");

          const textboxText = textbox ? norm(textbox.innerText) : null;
          const textboxEmpty = !textboxText || textboxText.length === 0;

	          // Common send failure surface text (best effort).
	          const bodyText = norm(document.body && document.body.innerText);
	          const sendError =
	            bodyText.includes("couldn't send") ||
	            bodyText.includes("could not send") ||
	            bodyText.includes("try again") && bodyText.includes("message");

	          const messageRequestInterstitial =
	            bodyText.includes("message request") ||
	            bodyText.includes("message requests") ||
	            (bodyText.includes("allow") && bodyText.includes("decline") && bodyText.includes("message"));

	          const alertTexts = Array.from(document.querySelectorAll("[role='alert'],[aria-live='polite'],[aria-live='assertive']"))
	            .map((n) => norm(n && (n.innerText || n.textContent)))
	            .filter((t) => t && t.length > 0)
	            .slice(0, 10);

	          // Best-effort: try to validate we are in the intended thread.
	          let threadMatches = null;
	          if (expected) {
	            const hrefs = Array.from(document.querySelectorAll("a[href^='/']"))
	              .map((a) => (a.getAttribute("href") || "").toLowerCase());
	            threadMatches = hrefs.some((h) => h === `/${expected}/` || h.startsWith(`/${expected}/`));
          }

          const nodes = Array.from(document.querySelectorAll(
            "div[role='row'], div[role='listitem'], [dir='auto'], span[data-lexical-text='true']"
          ));
          let bubbleFound = false;
          for (let i = nodes.length - 1; i >= 0 && i >= nodes.length - 400; i--) {
            const n = nodes[i];
            if (!n) continue;
            if (textbox && (textbox === n || textbox.contains(n) || n.contains(textbox))) continue;
            const t = norm(n.textContent || n.innerText);
            const a = norm(n.getAttribute && n.getAttribute("aria-label"));
            const combined = (t + " " + a).trim();
            if (combined && combined.includes(needle)) { bubbleFound = true; break; }
          }

	          return { textboxEmpty, textboxText, bubbleFound, threadMatches, sendError, messageRequestInterstitial, alertTexts };
	        JS

	        if last.is_a?(Hash) && last["sendError"] == true
	          return { ok: false, reason: "send_error_visible", details: last }
	        end

	        if last.is_a?(Hash) && last["messageRequestInterstitial"] == true
	          return { ok: false, reason: "message_request_interstitial_visible", details: last }
	        end

	        if last.is_a?(Hash) && last["textboxEmpty"] == true && last["bubbleFound"] == true
	          # If we can determine threadMatches, require it; otherwise accept.
	          if expected_username.to_s.strip.present?
	            tm = last["threadMatches"]
	            if tm.nil? || tm == true
	              return { ok: true, reason: "verified", details: last }
	            end
	          else
	            return { ok: true, reason: "verified", details: last }
	          end
	        end

	        sleep(0.75)

          # Fail fast if DM transport is broken at the browser/network layer.
          if (i % 4).zero?
            tls = detect_websocket_tls_issue(driver)
            if tls[:found]
              return {
                ok: false,
                reason: "websocket_tls_error #{tls[:reason]}",
                tls_issue: tls,
                details: last,
                expected_username: expected_username,
                message_preview: needle.byteslice(0, 80)
              }
            end
          end

	        # One refresh mid-way can help when the UI doesn't mount the most recent bubble immediately.
	        if i == 10
	          begin
	            driver.navigate.refresh
	            wait_for(driver, css: "body", timeout: 10)
	          rescue StandardError
	            nil
	          end
	        end
	      end

      tls = detect_websocket_tls_issue(driver)
      if tls[:found]
        return {
          ok: false,
          reason: "websocket_tls_error #{tls[:reason]}",
          tls_issue: tls,
          details: last,
          expected_username: expected_username,
          message_preview: needle.byteslice(0, 80)
        }
      end

      # If we couldn't find the bubble, but the textbox is empty, treat as "unknown" rather than success.
      textbox_empty = last.is_a?(Hash) ? last["textboxEmpty"] : nil
      bubble = last.is_a?(Hash) ? last["bubbleFound"] : nil
      thread = last.is_a?(Hash) ? last["threadMatches"] : nil

	      {
	        ok: false,
	        reason: "textbox_empty=#{textbox_empty.inspect} bubble_found=#{bubble.inspect} thread_matches=#{thread.inspect} message_request_interstitial=#{last.is_a?(Hash) ? last['messageRequestInterstitial'].inspect : 'nil'}",
	        details: last,
	        expected_username: expected_username,
	        message_preview: needle.byteslice(0, 80)
	      }
	    rescue StandardError => e
      { ok: false, reason: "verify_exception #{e.class}: #{e.message}" }
	    end

	    def click_dm_send_button(driver, textbox: nil)
	      return { clicked: false, reason: "no_textbox" } unless textbox
	      # Mark the send button in-DOM so we can click it via WebDriver actions (more reliable than JS click).
	      mark =
	        driver.execute_script(<<~JS, textbox)
	          const textbox = arguments[0];
	          if (!textbox) return { marked: false, reason: "no_textbox" };

	          // Clear previous marks (best effort).
	          try {
	            document.querySelectorAll("[data-codex-send-btn='1']").forEach((n) => n.removeAttribute("data-codex-send-btn"));
	          } catch (e) {}

	          const isVisible = (el) => {
	            if (!el) return false;
	            const style = window.getComputedStyle(el);
	            if (style.display === "none" || style.visibility === "hidden" || style.opacity === "0") return false;
	            const r = el.getBoundingClientRect();
	            return (r.width > 0 && r.height > 0);
	          };

	          const selectors = [
	            "[role='button'][aria-label='Send']",
	            "[role='button'][aria-label*='Send']",
	            "button[aria-label='Send']",
	            "button[aria-label*='Send']",
	            "svg[aria-label='Send']",
	            "svg[aria-label*='Send']"
	          ];

	          let root = textbox;
	          for (let depth = 0; depth < 10 && root; depth++) {
	            let candidate = null;
	            for (const sel of selectors) {
	              const el = root.querySelector ? root.querySelector(sel) : null;
	              if (el) { candidate = el; break; }
	            }

	            if (candidate) {
	              let button = candidate;
	              if (button && button.tagName && button.tagName.toLowerCase() === "svg") {
	                button = button.closest("button,[role='button']") || button;
	              }

	              const preview = (button && button.outerHTML ? button.outerHTML : "").slice(0, 900);
	              const ariaLabel = button && button.getAttribute ? button.getAttribute("aria-label") : null;
	              if (!button) return { marked: false, reason: "send_button_null" };
	              if (!isVisible(button)) return { marked: false, reason: "send_button_not_visible", ariaLabel, outerHTMLPreview: preview };

	              try { button.setAttribute("data-codex-send-btn", "1"); } catch (e) {}
	              return { marked: true, ariaLabel, outerHTMLPreview: preview };
	            }

	            root = root.parentElement;
	          }

	          return { marked: false, reason: "send_button_not_found_near_textbox" };
	        JS

	      mark = mark.to_h if mark.respond_to?(:to_h)
	      return { clicked: false, reason: "unexpected_js_return: #{mark.class}" } unless mark.is_a?(Hash)

	      mark = mark.transform_keys { |k| k.to_s.to_sym }
	      return { clicked: false, reason: mark[:reason] || "send_button_not_marked", aria_label: mark[:ariaLabel], outer_html_preview: mark[:outerHTMLPreview] } unless mark[:marked]

	      el = driver.find_element(css: "[data-codex-send-btn='1']")
	      begin
	        driver.action.move_to(el).click.perform
	      rescue StandardError
	        js_click(driver, el)
	      end

	      # Clean up the mark to avoid confusing later steps.
	      begin
	        driver.execute_script("arguments[0].removeAttribute('data-codex-send-btn');", el)
	      rescue StandardError
	        nil
	      end

	      { clicked: true, reason: "clicked", aria_label: mark[:ariaLabel], outer_html_preview: mark[:outerHTMLPreview] }
	    rescue StandardError => e
	      { clicked: false, reason: "send_click_exception #{e.class}: #{e.message}" }
	    end

    def mark_profile_dm_state!(profile:, state:, reason:, retry_after_at: nil)
      return unless profile

      can_message_value =
        case state.to_s
        when "messageable"
          true
        when "unknown"
          nil
        else
          false
        end

      payload = {
        can_message: can_message_value,
        restriction_reason: can_message_value == true ? nil : reason.to_s.presence,
        dm_interaction_state: state.to_s.presence,
        dm_interaction_reason: reason.to_s.presence,
        dm_interaction_checked_at: Time.current,
        dm_interaction_retry_after_at: retry_after_at
      }
      profile.update!(payload)
    rescue StandardError
      nil
    end

    def apply_dm_state_from_send_result(profile:, result:)
      return unless profile
      return unless result.is_a?(Hash)

      reason = result[:reason].to_s.presence || "send_failed"
      retry_after =
        if result[:api_http_status].to_i == 403
          Time.current + STORY_INTERACTION_RETRY_DAYS.days
        else
          Time.current + 12.hours
        end

      mark_profile_dm_state!(
        profile: profile,
        state: "unavailable",
        reason: reason,
        retry_after_at: retry_after
      )
    end
    end
  end
end
