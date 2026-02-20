module Instagram
  class Client
    module CommentPostingService
    def post_comment_to_media!(media_id:, shortcode:, comment_text:)
      text = comment_text.to_s.strip
      raise "Comment cannot be blank" if text.blank?
      raise "Media id is required to post comment" if media_id.to_s.strip.blank?
      raise "Post shortcode is required" if shortcode.to_s.strip.blank?

      with_recoverable_session(label: "post_comment") do
        with_authenticated_driver do |driver|
          with_task_capture(
            driver: driver,
            task_name: "post_comment_open_post",
            meta: { shortcode: shortcode.to_s, media_id: media_id.to_s }
          ) do
            driver.navigate.to("#{INSTAGRAM_BASE_URL}/p/#{shortcode}/")
            wait_for(driver, css: "body", timeout: 12)
            dismiss_common_overlays!(driver)
          end

          payload = post_comment_via_api_from_browser_context(
            driver: driver,
            media_id: media_id.to_s.strip,
            comment_text: text
          )

          parsed = parse_comment_api_payload(payload)
          return parsed[:body].merge("method" => "api", "media_id" => media_id.to_s) if parsed[:ok]

          # IG has started rejecting this endpoint on some sessions/builds with 403.
          # Fallback to visible UI interaction to preserve "Forward Post" behavior.
          capture_task_html(
            driver: driver,
            task_name: "post_comment_api_failed_fallback_ui",
            status: "error",
            meta: {
              shortcode: shortcode.to_s,
              media_id: media_id.to_s,
              api_status: parsed[:status],
              api_error: parsed[:error_message],
              api_response_preview: parsed[:response_preview]
            }
          )

          posted = comment_on_post_via_ui!(driver: driver, shortcode: shortcode.to_s, comment_text: text)
          raise "Instagram comment API returned HTTP #{parsed[:status]}; UI fallback also failed" unless posted

          {
            "status" => "ok",
            "method" => "ui_fallback",
            "api_status" => parsed[:status],
            "api_error" => parsed[:error_message],
            "media_id" => media_id.to_s
          }
        end
      end
    end

    def post_comment_via_api_from_browser_context(driver:, media_id:, comment_text:)
      driver.execute_async_script(
        <<~JS,
          const mediaId = arguments[0];
          const comment = arguments[1];
          const done = arguments[arguments.length - 1];

          const body = new URLSearchParams();
          body.set("comment_text", comment);

          const readCookie = (name) => {
            try {
              const cookie = document.cookie || "";
              const parts = cookie.split(";").map((v) => v.trim());
              const hit = parts.find((v) => v.startsWith(name + "="));
              if (!hit) return "";
              return decodeURIComponent(hit.slice(name.length + 1));
            } catch (e) {
              return "";
            }
          };

          const csrf = readCookie("csrftoken");
          const appId =
            document.querySelector("meta[property='al:ios:app_store_id']")?.getAttribute("content") ||
            "936619743392459";
          const rolloutHash =
            window._sharedData?.rollout_hash ||
            window.__initialData?.rollout_hash ||
            "";

          fetch(`/api/v1/web/comments/${mediaId}/add/`, {
            method: "POST",
            credentials: "include",
            headers: {
              "Accept": "application/json, text/plain, */*",
              "Content-Type": "application/x-www-form-urlencoded; charset=UTF-8",
              "X-Requested-With": "XMLHttpRequest",
              "X-CSRFToken": csrf,
              "X-IG-App-ID": appId,
              "X-Instagram-AJAX": rolloutHash,
              "Referer": window.location.href
            },
            body: body.toString()
          })
          .then(async (resp) => {
            const textBody = await resp.text();
            done({
              ok: resp.ok,
              status: resp.status,
              content_type: resp.headers.get("content-type") || "",
              body: textBody
            });
          })
          .catch((err) => {
            done({
              ok: false,
              status: 0,
              content_type: "",
              body: "",
              error: String(err)
            });
          });
        JS
        media_id.to_s.strip,
        comment_text.to_s
      )
    end

    def parse_comment_api_payload(payload)
      unless payload.is_a?(Hash)
        return {
          ok: false,
          status: nil,
          error_message: "Unexpected response while posting comment",
          response_preview: payload.to_s.byteslice(0, 500)
        }
      end

      status = payload["status"]
      body_raw = payload["body"].to_s
      ctype = payload["content_type"].to_s
      preview = body_raw.byteslice(0, 900)
      return { ok: false, status: status, error_message: payload["error"].to_s.presence || "Request failed", response_preview: preview } unless payload["ok"] == true

      return { ok: false, status: status, error_message: "Instagram comment API returned non-JSON response", response_preview: preview } unless ctype.include?("json")

      body = JSON.parse(body_raw) rescue {}
      body_status = body["status"].to_s
      return { ok: false, status: status, error_message: "Instagram comment API returned status=#{body_status.presence || 'unknown'}", response_preview: preview } unless body_status == "ok"

      { ok: true, status: status, body: body, response_preview: preview }
    end
    end
  end
end
