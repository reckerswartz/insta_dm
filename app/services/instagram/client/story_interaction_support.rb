module Instagram
  class Client
    module StoryInteractionSupport
      private

      def comment_on_post_via_ui!(driver:, shortcode:, comment_text:)
        driver.navigate.to("#{INSTAGRAM_BASE_URL}/p/#{shortcode}/")
        wait_for(driver, css: "body", timeout: 12)
        dismiss_common_overlays!(driver)
        capture_task_html(driver: driver, task_name: "auto_engage_post_opened", status: "ok", meta: { shortcode: shortcode })

        field = wait_for_comment_textbox(driver: driver)
        return false unless field

        focus_and_type(driver: driver, field: field, text: comment_text)
        posted = click_comment_post_button(driver: driver)
        sleep(0.6)
        capture_task_html(
          driver: driver,
          task_name: "auto_engage_post_comment_submit",
          status: posted ? "ok" : "error",
          meta: { shortcode: shortcode, posted: posted }
        )
        posted
      rescue StandardError
        false
      end

      def comment_on_story_via_ui!(driver:, comment_text:)
        field = wait_for_comment_textbox(driver: driver, timeout: 12)
        if !field
          availability = detect_story_reply_availability(driver)
          return {
            posted: false,
            reason: availability[:reason],
            marker_text: availability[:marker_text]
          }
        end

        capture_task_html(driver: driver, task_name: "auto_engage_story_reply_box_ready", status: "ok")
        focus_and_type(driver: driver, field: field, text: comment_text)
        posted = click_comment_post_button(driver: driver)
        if posted
          return { posted: true, reason: "post_button_clicked" }
        end

        enter_posted = send_enter_comment(driver: driver, field: field)
        return { posted: true, reason: "submitted_with_enter" } if enter_posted

        { posted: false, reason: "submit_controls_not_found" }
      rescue StandardError => e
        { posted: false, reason: "exception:#{e.class.name}" }
      end

      # API-first story reply path discovered from captured network traces:
      # 1) POST /api/v1/direct_v2/create_group_thread/ with recipient_users=["<reel_user_id>"]
      # 2) POST /api/v1/direct_v2/threads/broadcast/reel_share/ with media_id="<story_id>_<reel_user_id>", reel_id, thread_id, text
      def comment_on_story_via_api!(story_id:, story_username:, comment_text:)
        text = comment_text.to_s.strip
        return { posted: false, method: "api", reason: "blank_comment_text" } if text.blank?

        sid = story_id.to_s.strip.gsub(/[^0-9]/, "")
        return { posted: false, method: "api", reason: "missing_story_id" } if sid.blank?

        username = normalize_username(story_username)
        return { posted: false, method: "api", reason: "missing_story_username" } if username.blank?

        user_id = story_user_id_for(username: username)
        return { posted: false, method: "api", reason: "missing_story_user_id" } if user_id.blank?

        thread_id = direct_thread_id_for_user(user_id: user_id)
        return { posted: false, method: "api", reason: "missing_thread_id" } if thread_id.blank?

        payload = {
          action: "send_item",
          client_context: story_api_client_context,
          media_id: "#{sid}_#{user_id}",
          reel_id: user_id,
          text: text,
          thread_id: thread_id
        }

        body = ig_api_post_form_json(
          path: "/api/v1/direct_v2/threads/broadcast/reel_share/",
          referer: "#{INSTAGRAM_BASE_URL}/stories/#{username}/#{sid}/",
          form: payload
        )
        return { posted: false, method: "api", reason: "empty_api_response" } unless body.is_a?(Hash)

        status = body["status"].to_s
        if status == "ok"
          return {
            posted: true,
            method: "api",
            reason: "reel_share_sent",
            api_status: status,
            api_thread_id: body.dig("payload", "thread_id").to_s.presence,
            api_item_id: body.dig("payload", "item_id").to_s.presence
          }
        end

        {
          posted: false,
          method: "api",
          reason: body["message"].to_s.presence || body.dig("payload", "message").to_s.presence || body["error_type"].to_s.presence || "api_status_#{status.presence || 'unknown'}",
          api_status: status.presence || "unknown",
          api_http_status: body["_http_status"],
          api_error_code: body.dig("payload", "error_code").to_s.presence || body["error_code"].to_s.presence
        }
      rescue StandardError => e
        { posted: false, method: "api", reason: "api_exception:#{e.class.name}" }
      end

      def story_user_id_for(username:)
        @story_user_id_cache ||= {}
        uname = normalize_username(username)
        return "" if uname.blank?
        cached = @story_user_id_cache[uname].to_s
        return cached if cached.present?

        web_info = fetch_web_profile_info(uname)
        user = web_info.is_a?(Hash) ? web_info.dig("data", "user") : nil
        uid = user.is_a?(Hash) ? user["id"].to_s.strip : ""
        @story_user_id_cache[uname] = uid if uid.present?
        uid
      rescue StandardError
        ""
      end

      def direct_thread_id_for_user(user_id:)
        create_direct_thread_for_user(user_id: user_id, use_cache: true)[:thread_id].to_s
      rescue StandardError
        ""
      end

      def create_direct_thread_for_user(user_id:, use_cache: true)
        @story_reply_thread_cache ||= {}
        uid = user_id.to_s.strip
        return { thread_id: "", reason: "blank_user_id" } if uid.blank?

        if use_cache
          cached = @story_reply_thread_cache[uid].to_s
          return { thread_id: cached, reason: "cache_hit" } if cached.present?
        end

        body = ig_api_post_form_json(
          path: "/api/v1/direct_v2/create_group_thread/",
          referer: "#{INSTAGRAM_BASE_URL}/direct/new/",
          form: { recipient_users: [ uid ].to_json }
        )
        return { thread_id: "", reason: "empty_api_response" } unless body.is_a?(Hash)

        thread_id =
          body["thread_id"].to_s.presence ||
          body.dig("thread", "thread_id").to_s.presence ||
          body.dig("thread", "id").to_s.presence

        if thread_id.present?
          @story_reply_thread_cache[uid] = thread_id
          return {
            thread_id: thread_id,
            reason: "thread_created",
            api_status: body["status"].to_s.presence || "ok",
            api_http_status: body["_http_status"]
          }
        end

        {
          thread_id: "",
          reason: body["message"].to_s.presence || body["error_type"].to_s.presence || "missing_thread_id",
          api_status: body["status"].to_s.presence || "unknown",
          api_http_status: body["_http_status"],
          api_error_code: body["error_code"].to_s.presence || body.dig("payload", "error_code").to_s.presence
        }
      rescue StandardError => e
        { thread_id: "", reason: "api_exception:#{e.class.name}" }
      end

      def story_api_client_context
        "#{(Time.current.to_f * 1000).to_i}#{rand(1_000_000..9_999_999)}"
      end

      def ig_api_post_form_json(path:, referer:, form:)
        uri = URI.parse(path.to_s.start_with?("http") ? path.to_s : "#{INSTAGRAM_BASE_URL}#{path}")

        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = (uri.scheme == "https")
        http.open_timeout = 10
        http.read_timeout = 20

        req = Net::HTTP::Post.new(uri.request_uri)
        req["User-Agent"] = @account.user_agent.presence || "Mozilla/5.0"
        req["Accept"] = "application/json, text/plain, */*"
        req["Content-Type"] = "application/x-www-form-urlencoded; charset=UTF-8"
        req["X-Requested-With"] = "XMLHttpRequest"
        req["X-IG-App-ID"] = (@account.auth_snapshot.dig("ig_app_id").presence || "936619743392459")
        req["Referer"] = referer.to_s

        csrf = @account.cookies.find { |c| c["name"].to_s == "csrftoken" }&.dig("value").to_s
        req["X-CSRFToken"] = csrf if csrf.present?
        req["Cookie"] = cookie_header_for(@account.cookies)
        req.set_form_data(form.transform_values { |v| v.to_s })

        res = http.request(req)
        return nil unless res["content-type"].to_s.include?("json")

        body = JSON.parse(res.body.to_s)
        body["_http_status"] = res.code.to_i
        body
      rescue StandardError
        nil
      end

      def detect_story_reply_availability(driver)
        payload = driver.execute_script(<<~JS)
          const out = { reason: "reply_box_not_found", marker_text: "" };
          const norm = (value) => (value || "").toString().replace(/\\s+/g, " ").trim().toLowerCase();
          const texts = Array.from(document.querySelectorAll("body *"))
            .filter((el) => {
              if (!el) return false;
              if (el.children && el.children.length > 0) return false;
              const r = el.getBoundingClientRect();
              return r.width > 3 && r.height > 3;
            })
            .map((el) => norm(el.innerText || el.textContent))
            .filter((t) => t.length > 0 && t.length < 140);

          const joined = texts.join(" | ");
          const matchAny = (patterns) => patterns.find((p) => joined.includes(p));

          const repliesNotAllowed = matchAny([
            "replies aren't available",
            "replies are turned off",
            "replies are off",
            "can't reply to this story",
            "you can't reply to this story",
            "reply unavailable"
          ]);
          if (repliesNotAllowed) {
            out.reason = "replies_not_allowed";
            out.marker_text = repliesNotAllowed;
            return out;
          }

          const unavailable = matchAny([
            "story unavailable",
            "this story is unavailable",
            "content unavailable",
            "not available right now",
            "unavailable"
          ]);
          if (unavailable) {
            out.reason = "reply_unavailable";
            out.marker_text = unavailable;
            return out;
          }

          return out;
        JS

        return { reason: "reply_box_not_found", marker_text: "" } unless payload.is_a?(Hash)

        {
          reason: payload["reason"].to_s.presence || "reply_box_not_found",
          marker_text: payload["marker_text"].to_s
        }
      rescue StandardError
        { reason: "reply_box_not_found", marker_text: "" }
      end

      def story_reply_skip_status_for(comment_result = nil, reason: nil)
        reason = reason.to_s if reason.present?
        reason ||= comment_result.to_h[:reason].to_s
        case reason
        when "api_can_reply_false"
          { reason_code: "api_can_reply_false", status: "Replies not allowed (API)" }
        when "reply_box_not_found"
          { reason_code: "reply_box_not_found", status: "Reply box not found" }
        when "replies_not_allowed"
          { reason_code: "replies_not_allowed", status: "Replies not allowed" }
        when "reply_unavailable"
          { reason_code: "reply_unavailable", status: "Unavailable" }
        when "reply_precheck_error"
          { reason_code: "reply_precheck_error", status: "Unavailable" }
        else
          { reason_code: "comment_submit_failed", status: "Unavailable" }
        end
      end

      def story_reply_capability_from_api(username:, story_id:, driver: nil, cache: nil)
        item = resolve_story_item_via_api(username: username, story_id: story_id, driver: driver, cache: cache)
        return { known: false, reply_possible: nil, reason_code: "api_story_not_found", status: "Unknown" } unless item.is_a?(Hash)

        can_reply = item[:can_reply]
        return { known: false, reply_possible: nil, reason_code: "api_can_reply_missing", status: "Unknown" } if can_reply.nil?

        if can_reply
          { known: true, reply_possible: true, reason_code: nil, status: "Reply available (API)" }
        else
          { known: true, reply_possible: false, reason_code: "api_can_reply_false", status: "Replies not allowed (API)" }
        end
      rescue StandardError => e
        { known: false, reply_possible: nil, reason_code: "api_capability_error", status: "Unknown" }
      end

      def story_external_profile_link_context_from_api(username:, story_id:, cache: nil, driver: nil)
        item = resolve_story_item_via_api(username: username, story_id: story_id, cache: cache, driver: driver)
        return { known: false, has_external_profile_link: false, reason_code: "api_story_not_found", linked_username: "", linked_profile_url: "", marker_text: "", linked_targets: [] } unless item.is_a?(Hash)

        has_external = ActiveModel::Type::Boolean.new.cast(item[:api_has_external_profile_indicator])
        return { known: true, has_external_profile_link: false, reason_code: nil, linked_username: "", linked_profile_url: "", marker_text: "", linked_targets: [] } unless has_external

        reason = item[:api_external_profile_reason].to_s.presence || "api_external_profile_indicator"
        targets = Array(item[:api_external_profile_targets]).map(&:to_s).map(&:strip).reject(&:blank?).uniq
        {
          known: true,
          has_external_profile_link: true,
          reason_code: reason,
          linked_username: "",
          linked_profile_url: "",
          marker_text: reason,
          linked_targets: targets
        }
      rescue StandardError
        { known: false, has_external_profile_link: false, reason_code: "api_external_context_error", linked_username: "", linked_profile_url: "", marker_text: "", linked_targets: [] }
      end

      def check_story_reply_capability(driver:)
        field = wait_for_comment_textbox(driver: driver, timeout: 2)
        return { reply_possible: true, reason_code: nil, status: "Reply available", marker_text: "", submission_reason: "reply_box_found" } if field

        availability = detect_story_reply_availability(driver)
        status = story_reply_skip_status_for(reason: availability[:reason])
        {
          reply_possible: false,
          reason_code: status[:reason_code],
          status: status[:status],
          marker_text: availability[:marker_text].to_s,
          submission_reason: availability[:reason].to_s
        }
      rescue StandardError => e
        {
          reply_possible: false,
          reason_code: "reply_precheck_error",
          status: "Unavailable",
          marker_text: "",
          submission_reason: "exception:#{e.class.name}"
        }
      end

      def react_to_story_if_available!(driver:)
        payload = driver.execute_script(<<~JS)
          const out = { reacted: false, reason: "reaction_controls_not_found", marker_text: "" };
          const norm = (value) => (value || "").toString().replace(/\\s+/g, " ").trim().toLowerCase();
          const isVisible = (el) => {
            if (!el) return false;
            const s = window.getComputedStyle(el);
            if (!s || s.display === "none" || s.visibility === "hidden" || s.opacity === "0") return false;
            const r = el.getBoundingClientRect();
            if (r.width < 4 || r.height < 4) return false;
            return r.bottom > 0 && r.top < window.innerHeight;
          };

          const candidates = Array.from(document.querySelectorAll("button, [role='button']"))
            .filter((el) => {
              if (!isVisible(el)) return false;
              const r = el.getBoundingClientRect();
              return r.top >= Math.max(0, window.innerHeight * 0.45);
            });

          const scoreFor = (el) => {
            const text = norm(el.innerText || el.textContent);
            const aria = norm(el.getAttribute && el.getAttribute("aria-label"));
            const title = norm(el.getAttribute && el.getAttribute("title"));
            const all = `${text} | ${aria} | ${title}`;
            if (all.includes("quick reaction")) return 100;
            if (all.includes("reaction")) return 95;
            if (all.includes("react")) return 90;
            if (all.includes("like")) return 75;
            if (all.includes("heart")) return 70;
            if (/[❤️❤🔥😍😂👏😢😮]/.test(text)) return 60;
            return 0;
          };

          const sorted = candidates
            .map((el) => ({ el, score: scoreFor(el) }))
            .filter((entry) => entry.score > 0)
            .sort((a, b) => b.score - a.score);

          const chosen = sorted[0];
          if (!chosen || !chosen.el) return out;

          const marker = norm(chosen.el.innerText || chosen.el.textContent) || norm(chosen.el.getAttribute && chosen.el.getAttribute("aria-label")) || "reaction_button";
          try {
            chosen.el.click();
            out.reacted = true;
            out.reason = "reaction_button_clicked";
            out.marker_text = marker;
            return out;
          } catch (e) {
            out.reason = "reaction_click_failed";
            out.marker_text = marker;
            return out;
          }
        JS

        return { reacted: false, reason: "reaction_detection_error", marker_text: "" } unless payload.is_a?(Hash)

        {
          reacted: ActiveModel::Type::Boolean.new.cast(payload["reacted"]),
          reason: payload["reason"].to_s.presence || "reaction_controls_not_found",
          marker_text: payload["marker_text"].to_s
        }
      rescue StandardError => e
        { reacted: false, reason: "reaction_exception:#{e.class.name}", marker_text: "" }
      end

      def dm_interaction_retry_pending?(profile)
        return false unless profile
        return false unless profile.dm_interaction_state.to_s == "unavailable"

        retry_after = profile.dm_interaction_retry_after_at
        retry_after.present? && retry_after > Time.current
      end



      def profile_interaction_retry_pending?(profile)
        return false unless profile
        return false unless profile.story_interaction_state.to_s == "unavailable"

        retry_after = profile.story_interaction_retry_after_at
        retry_after.present? && retry_after > Time.current
      end

      def mark_profile_interaction_state!(profile:, state:, reason:, reaction_available:, retry_after_at: nil)
        return unless profile

        profile.update!(
          story_interaction_state: state.to_s.presence,
          story_interaction_reason: reason.to_s.presence,
          story_interaction_checked_at: Time.current,
          story_interaction_retry_after_at: retry_after_at,
          story_reaction_available: reaction_available.nil? ? profile.story_reaction_available : ActiveModel::Type::Boolean.new.cast(reaction_available)
        )
      rescue StandardError
        nil
      end


      def wait_for_comment_textbox(driver:, timeout: 10)
        Selenium::WebDriver::Wait.new(timeout: timeout).until do
          el =
            driver.find_elements(css: "textarea[aria-label*='comment'], textarea[aria-label*='Comment'], textarea[placeholder*='comment'], textarea[placeholder*='Comment'], textarea[placeholder*='reply'], textarea[placeholder*='Reply']").find { |x| x.displayed? rescue false } ||
            driver.find_elements(css: "div[role='textbox'][contenteditable='true']").find { |x| x.displayed? rescue false }
          break el if el
        end
      rescue Selenium::WebDriver::Error::TimeoutError
        nil
      end

      def focus_and_type(driver:, field:, text:)
        begin
          driver.execute_script("arguments[0].scrollIntoView({block:'center'});", field)
        rescue StandardError
          nil
        end

        begin
          field.click
        rescue StandardError
          nil
        end

        if field.tag_name.to_s.downcase == "div"
          driver.execute_script("arguments[0].focus();", field)
          field.send_keys(text.to_s)
        else
          field.send_keys([ :control, "a" ])
          field.send_keys(:backspace)
          field.send_keys(text.to_s)
        end
      end

      def click_comment_post_button(driver:)
        button =
          driver.find_elements(xpath: "//*[self::button or (self::div and @role='button')][normalize-space()='Post']").find { |el| element_enabled?(el) } ||
          driver.find_elements(xpath: "//*[self::button or (self::div and @role='button')][normalize-space()='Reply']").find { |el| element_enabled?(el) } ||
          driver.find_elements(xpath: "//*[self::button or (self::div and @role='button')][contains(translate(normalize-space(.), 'ABCDEFGHIJKLMNOPQRSTUVWXYZ', 'abcdefghijklmnopqrstuvwxyz'), 'post')]").find { |el| element_enabled?(el) } ||
          driver.find_elements(xpath: "//*[self::button or (self::div and @role='button')][contains(translate(normalize-space(.), 'ABCDEFGHIJKLMNOPQRSTUVWXYZ', 'abcdefghijklmnopqrstuvwxyz'), 'reply')]").find { |el| element_enabled?(el) }
        return false unless button

        begin
          driver.action.move_to(button).click.perform
        rescue StandardError
          js_click(driver, button)
        end
        true
      rescue StandardError
        false
      end

      def send_enter_comment(driver:, field:)
        begin
          driver.action.click(field).send_keys(:enter).perform
          true
        rescue StandardError
          false
        end
      end
    end
  end
end
