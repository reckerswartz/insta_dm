module Instagram
  class Client
    module StoryApiSupport
      IG_API_RATE_LIMIT_CACHE_PREFIX = "instagram:api:rate_limit".freeze
      IG_API_USAGE_CACHE_PREFIX = "instagram:api:usage".freeze

      private

      def ig_api_get_json(path:, referer:, endpoint: nil, username: nil, driver: nil, retries: 2)
        uri = URI.parse(path.to_s.start_with?("http") ? path.to_s : "#{INSTAGRAM_BASE_URL}#{path}")
        endpoint_name = endpoint.to_s.presence || infer_ig_api_endpoint(uri.path)
        normalized_username = normalize_username(username)
        paused = ig_api_endpoint_paused?(endpoint: endpoint_name, username: normalized_username)
        if paused
          log_ig_api_get_failure(
            endpoint: endpoint_name,
            uri: uri,
            username: normalized_username,
            failure: {
              status: 429,
              reason: paused[:reason].to_s.presence || "local_rate_limit_pause",
              body: "blocked by local rate limiter",
              retry_after_seconds: paused[:retry_after_seconds].to_i,
              headers: paused[:headers].is_a?(Hash) ? paused[:headers] : {}
            },
            attempts: 0,
            tried_browser_fallback: false
          )
          return nil
        end

        attempts = 0
        max_attempts = retries.to_i.clamp(0, 4) + 1
        failure = nil

        while attempts < max_attempts
          attempts += 1
          apply_ig_api_request_spacing!(endpoint: endpoint_name, username: normalized_username)
          response = perform_ig_api_get(uri: uri, referer: referer)
          record_ig_api_usage!(
            endpoint: endpoint_name,
            username: normalized_username,
            method: "GET",
            status: response[:status].to_i
          )
          apply_ig_api_rate_limit_state!(
            endpoint: endpoint_name,
            uri: uri,
            username: normalized_username,
            status: response[:status].to_i,
            headers: response[:headers],
            reason: response[:reason]
          )
          if response[:ok]
            parsed = parse_ig_api_json(response[:body])
            return parsed if parsed.is_a?(Hash) || parsed.is_a?(Array)

            failure = response.merge(reason: "invalid_json_response")
          else
            failure = response
          end

          break unless retryable_ig_api_failure?(failure)
          sleep(resolve_ig_api_retry_delay_seconds(failure: failure, attempt: attempts))
        end

        browser_response = nil
        if driver
          browser_response = ig_api_get_json_via_browser(driver: driver, path: uri.to_s)
          record_ig_api_usage!(
            endpoint: endpoint_name,
            username: normalized_username,
            method: "GET(browser)",
            status: browser_response[:status].to_i
          )
          apply_ig_api_rate_limit_state!(
            endpoint: endpoint_name,
            uri: uri,
            username: normalized_username,
            status: browser_response[:status].to_i,
            headers: browser_response[:headers],
            reason: browser_response[:reason]
          )
          return browser_response[:payload] if browser_response[:ok]

          failure = browser_response if browser_response.is_a?(Hash)
        end

        log_ig_api_get_failure(
          endpoint: endpoint_name,
          uri: uri,
          username: normalized_username,
          failure: failure || {},
          attempts: attempts,
          tried_browser_fallback: driver.present?
        )
        nil
      rescue StandardError => e
        log_ig_api_get_failure(
          endpoint: endpoint.to_s.presence || "unknown",
          uri: uri,
          username: normalized_username,
          failure: { status: 0, reason: "exception:#{e.class.name}", body: e.message.to_s },
          attempts: 1,
          tried_browser_fallback: driver.present?
        )
        nil
      end

      def perform_ig_api_get(uri:, referer:)
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = (uri.scheme == "https")
        http.open_timeout = 10
        http.read_timeout = 20

        req = Net::HTTP::Get.new(uri.request_uri)
        req["User-Agent"] = @account.user_agent.presence || "Mozilla/5.0"
        req["Accept"] = "application/json, text/plain, */*"
        req["X-Requested-With"] = "XMLHttpRequest"
        req["X-IG-App-ID"] = ig_api_app_id_header_value
        ig_www_claim = ig_www_claim_header_value
        req["X-IG-WWW-Claim"] = ig_www_claim if ig_www_claim.present?
        req["Referer"] = referer.to_s

        csrf = @account.cookies.find { |c| c["name"].to_s == "csrftoken" }&.dig("value").to_s
        req["X-CSRFToken"] = csrf if csrf.present?
        req["Cookie"] = cookie_header_for(@account.cookies)

        res = http.request(req)
        status = res.code.to_i
        {
          ok: res.is_a?(Net::HTTPSuccess),
          status: status,
          reason: (res.is_a?(Net::HTTPSuccess) ? nil : "http_#{status}"),
          body: res.body.to_s,
          content_type: res["content-type"].to_s,
          headers: extract_ig_rate_limit_headers(res)
        }
      rescue StandardError => e
        { ok: false, status: 0, reason: "request_exception:#{e.class.name}", body: e.message.to_s, content_type: "", headers: {} }
      end

      def parse_ig_api_json(raw_body)
        body = raw_body.to_s
        return nil if body.blank?

        JSON.parse(body)
      rescue StandardError
        nil
      end

      def ig_api_app_id_header_value
        @account.auth_snapshot.dig("ig_app_id").to_s.presence || "936619743392459"
      rescue StandardError
        "936619743392459"
      end

      def ig_www_claim_header_value
        claim = read_stored_session_storage_value("www-claim-v2")
        claim.to_s.strip.presence
      rescue StandardError
        nil
      end

      def read_stored_session_storage_value(key)
        target = key.to_s
        row = Array(@account.session_storage).find do |entry|
          entry.is_a?(Hash) && entry["key"].to_s == target
        end
        row.is_a?(Hash) ? row["value"].to_s : ""
      rescue StandardError
        ""
      end

      def ig_api_get_json_via_browser(driver:, path:)
        payload = driver.execute_async_script(<<~JS, path.to_s, ig_api_app_id_header_value.to_s, ig_www_claim_header_value.to_s)
          const endpoint = String(arguments[0] || "");
          const fallbackAppId = String(arguments[1] || "");
          const fallbackClaim = String(arguments[2] || "");
          const done = arguments[arguments.length - 1];
          if (!endpoint) {
            done({ ok: false, status: 0, reason: "blank_endpoint", body_snippet: "" });
            return;
          }

          const normalizeHeaderValue = (value) => String(value || "").trim();
          const igAppId = normalizeHeaderValue(
            document.documentElement?.getAttribute("data-app-id") ||
            window._sharedData?.config?.app_id ||
            window.__initialData?.config?.app_id ||
            window.localStorage?.getItem("ig_app_id") ||
            window.localStorage?.getItem("app_id") ||
            window.sessionStorage?.getItem("ig_app_id") ||
            fallbackAppId
          );
          const igWwwClaim = normalizeHeaderValue(
            window.sessionStorage?.getItem("www-claim-v2") ||
            fallbackClaim
          );

          const headers = {
            "Accept": "application/json, text/plain, */*",
            "X-Requested-With": "XMLHttpRequest"
          };
          if (igAppId) headers["X-IG-App-ID"] = igAppId;
          if (igWwwClaim) headers["X-IG-WWW-Claim"] = igWwwClaim;

          const options = {
            method: "GET",
            credentials: "include",
            headers: headers
          };

          fetch(endpoint, options)
            .then(async (resp) => {
              const text = await resp.text();
              let parsed = null;
              let parseError = null;
              try { parsed = JSON.parse(text); } catch (e) { parseError = "invalid_json_response"; }

              done({
                ok: Boolean(resp.ok && parsed && (typeof parsed === "object")),
                status: Number(resp.status || 0),
                reason: (!resp.ok ? `http_${resp.status}` : parseError),
                payload: parsed,
                body_snippet: String(text || "").slice(0, 320)
              });
            })
            .catch((error) => {
              done({
                ok: false,
                status: 0,
                reason: `browser_fetch_exception:${String((error && error.message) || error || "unknown")}`,
                payload: null,
                body_snippet: ""
              });
            });
        JS

        result = payload.is_a?(Hash) ? payload : {}
        status = result["status"].to_i
        data = result["payload"]
        {
          ok: result["ok"] == true && (data.is_a?(Hash) || data.is_a?(Array)),
          status: status,
          reason: result["reason"].to_s.presence || "browser_fetch_failed",
          payload: data,
          body: result["body_snippet"].to_s,
          headers: {}
        }
      rescue StandardError => e
        { ok: false, status: 0, reason: "browser_fetch_exception:#{e.class.name}", payload: nil, body: e.message.to_s, headers: {} }
      end

      def retryable_ig_api_failure?(failure)
        status = failure[:status].to_i
        return true if status == 429
        return true if status >= 500
        return true if status <= 0

        false
      rescue StandardError
        false
      end

      def infer_ig_api_endpoint(path)
        value = path.to_s
        return "unknown" if value.blank?

        if (match = value.match(%r{/api/v1/([^?]+)}))
          return match[1].to_s.gsub(%r{/$}, "")
        end

        value.gsub(%r{\A/}, "")
      rescue StandardError
        "unknown"
      end

      def log_ig_api_get_failure(endpoint:, uri:, username:, failure:, attempts:, tried_browser_fallback:)
        status = failure[:status].to_i
        reason = failure[:reason].to_s.presence || "request_failed"
        response_snippet = failure[:body].to_s.byteslice(0, 300)
        retry_after_seconds = failure[:retry_after_seconds].to_i
        normalized_username = normalize_username(username)
        rate_limit_headers = failure[:headers].is_a?(Hash) ? failure[:headers] : {}
        useragent_mismatch = ig_useragent_mismatch_failure?(reason: reason, response_snippet: response_snippet)

        if status.positive? && respond_to?(:remember_story_api_failure!, true)
          remember_story_api_failure!(
            endpoint: endpoint.to_s.presence || "unknown",
            url: uri.to_s,
            status: status,
            username: normalized_username,
            reason: reason,
            response_snippet: response_snippet,
            retry_after_seconds: retry_after_seconds,
            headers: rate_limit_headers
          )
        end

        Ops::StructuredLogger.warn(
          event: "instagram.api_get_json.failure",
          payload: {
            endpoint: endpoint.to_s.presence || "unknown",
            url: uri.to_s,
            status: (status.positive? ? status : nil),
            username: normalized_username.presence,
            reason: reason,
            attempts: attempts.to_i,
            rate_limited: status == 429,
            retry_after_seconds: (retry_after_seconds.positive? ? retry_after_seconds : nil),
            browser_fallback_attempted: tried_browser_fallback,
            useragent_mismatch: useragent_mismatch,
            rate_limit_headers: rate_limit_headers.presence,
            response_snippet: response_snippet
          }.compact
        )
      rescue StandardError
        nil
      end

      def fetch_story_reel(user_id:, referer_username:, driver: nil)
        uid = user_id.to_s.strip
        uname = normalize_username(referer_username)
        return nil if uid.blank? || uname.blank?

        body = ig_api_get_json(
          path: "/api/v1/feed/reels_media/?reel_ids=#{CGI.escape(uid)}",
          referer: "#{INSTAGRAM_BASE_URL}/#{uname}/",
          endpoint: "feed/reels_media",
          username: uname,
          driver: driver,
          retries: 2
        )
        return nil unless body.is_a?(Hash)
      
        # Debug: Capture raw story reel data
        debug_story_reel_data(referer_username: uname, user_id: uid, body: body)
      
        reels = body["reels"]
        if reels.is_a?(Hash)
          direct = reels[uid]
          return direct if direct.is_a?(Hash)

          by_owner = reels.values.find { |entry| reel_entry_owner_id(entry) == uid }
          return by_owner if by_owner.is_a?(Hash)

          Ops::StructuredLogger.warn(
            event: "instagram.story_reel.requested_reel_missing",
            payload: {
              requested_user_id: uid,
              referer_username: uname,
              available_reel_keys: reels.keys.first(10),
              reels_count: reels.size
            }
          )
          return nil
        end

        reels_media = body["reels_media"]
        if reels_media.is_a?(Array)
          by_owner = reels_media.find { |entry| reel_entry_owner_id(entry) == uid }
          return by_owner if by_owner.is_a?(Hash)

          Ops::StructuredLogger.warn(
            event: "instagram.story_reel.reels_media_owner_missing",
            payload: {
              requested_user_id: uid,
              referer_username: uname,
              reels_media_count: reels_media.length
            }
          )
          return nil
        end

        body
      rescue StandardError
        nil
      end

      def resolve_story_media_for_current_context(driver:, username:, story_id:, fallback_story_key:, cache: nil)
        uname = normalize_username(username)
        sid = normalize_story_id_token(story_id)
        fallback_key = fallback_story_key.to_s

        api_story = resolve_story_item_via_api(username: uname, story_id: sid, cache: cache, driver: driver)
        if api_story.is_a?(Hash)
          url = api_story[:media_url].to_s
          if downloadable_story_media_url?(url)
            return {
              media_type: api_story[:media_type].to_s.presence || "unknown",
              url: url,
              width: api_story[:width],
              height: api_story[:height],
              source: "api_reels_media",
              story_id: api_story[:story_id].to_s,
              image_url: api_story[:image_url].to_s.presence,
              video_url: api_story[:video_url].to_s.presence,
              owner_user_id: api_story[:owner_user_id].to_s.presence,
              owner_username: api_story[:owner_username].to_s.presence,
              media_variant_count: Array(api_story[:media_variants]).length,
              primary_media_index: api_story[:primary_media_index],
              primary_media_source: api_story[:primary_media_source].to_s.presence,
              carousel_media: Array(api_story[:carousel_media])
            }
          end
        end

        dom_story = resolve_story_item_via_dom(driver: driver)
        if dom_story.is_a?(Hash)
          dom_media_url = dom_story[:media_url].to_s
          if downloadable_story_media_url?(dom_media_url)
            hinted_story_id = normalize_story_id_token(story_id_hint_from_media_url(dom_media_url))
            return {
              media_type: dom_story[:media_type].to_s.presence || "unknown",
              url: dom_media_url,
              width: dom_story[:width],
              height: dom_story[:height],
              source: "dom_visible_media",
              story_id: sid.presence || hinted_story_id.presence || "",
              image_url: dom_story[:image_url].to_s.presence,
              video_url: dom_story[:video_url].to_s.presence,
              owner_user_id: nil,
              owner_username: nil,
              media_variant_count: 1,
              primary_media_index: 0,
              primary_media_source: "dom",
              carousel_media: []
            }
          end
        end

        perf_story = resolve_story_item_via_performance_logs(driver: driver)
        if perf_story.is_a?(Hash)
          perf_media_url = perf_story[:media_url].to_s
          if downloadable_story_media_url?(perf_media_url)
            hinted_story_id = normalize_story_id_token(story_id_hint_from_media_url(perf_media_url))
            return {
              media_type: perf_story[:media_type].to_s.presence || "unknown",
              url: perf_media_url,
              width: perf_story[:width],
              height: perf_story[:height],
              source: "performance_logs_media",
              story_id: sid.presence || hinted_story_id.presence || "",
              image_url: perf_story[:image_url].to_s.presence,
              video_url: perf_story[:video_url].to_s.presence,
              owner_user_id: nil,
              owner_username: nil,
              media_variant_count: 1,
              primary_media_index: 0,
              primary_media_source: "performance_logs",
              carousel_media: []
            }
          end
        end

        Ops::StructuredLogger.warn(
          event: "instagram.story_media.api_unresolved",
          payload: {
            username: uname,
            story_id: sid.presence,
            story_key: fallback_key.presence,
            source: "api_then_dom_resolution"
          }
        )
        {
          media_type: nil,
          url: nil,
          width: nil,
          height: nil,
          source: "api_unresolved",
          story_id: sid,
          image_url: nil,
          video_url: nil,
          owner_user_id: nil,
          owner_username: nil,
          media_variant_count: 0,
          primary_media_index: nil,
          primary_media_source: nil,
          carousel_media: []
        }
      rescue StandardError
        {
          media_type: nil,
          url: nil,
          width: nil,
          height: nil,
          source: "api_unresolved_error",
          story_id: sid,
          image_url: nil,
          video_url: nil,
          owner_user_id: nil,
          owner_username: nil,
          media_variant_count: 0,
          primary_media_index: nil,
          primary_media_source: nil,
          carousel_media: []
        }
      end

      def resolve_story_item_via_dom(driver:)
        payload = driver.execute_script(<<~JS)
          const out = {
            media_url: "",
            media_type: "",
            image_url: "",
            video_url: "",
            width: null,
            height: null
          };

          const isVisible = (el) => {
            if (!el) return false;
            const style = window.getComputedStyle(el);
            if (!style || style.display === "none" || style.visibility === "hidden" || style.opacity === "0") return false;
            const rect = el.getBoundingClientRect();
            if (rect.width < 220 || rect.height < 220) return false;
            return rect.bottom > 0 && rect.top < window.innerHeight;
          };

          const absUrl = (value) => {
            if (!value) return "";
            const str = value.toString().trim();
            if (!str) return "";
            try { return new URL(str, window.location.href).toString(); } catch (e) { return str; }
          };

          const blockedAvatarLikeUrl = (value) => {
            const src = (value || "").toString().toLowerCase();
            if (!src) return true;
            if (src.startsWith("data:")) return true;
            if (src.startsWith("blob:")) return true;
            if (src.startsWith("mediastream:")) return true;
            if (src.startsWith("javascript:")) return true;
            if (src.includes("/t51.2885-19/")) return true;
            if (src.includes("profile_pic")) return true;
            if (src.includes("s150x150")) return true;
            return false;
          };

          const centerBonus = (rect) => {
            const cx = rect.left + (rect.width / 2);
            const cy = rect.top + (rect.height / 2);
            const dx = Math.abs(cx - (window.innerWidth / 2));
            const dy = Math.abs(cy - (window.innerHeight / 2));
            const distance = Math.sqrt((dx * dx) + (dy * dy));
            return Math.max(0, 500 - distance);
          };

          const candidates = [];
          Array.from(document.querySelectorAll("video, img")).forEach((el) => {
            if (!isVisible(el)) return;
            const rect = el.getBoundingClientRect();
            const mediaType = el.tagName.toLowerCase() === "video" ? "video" : "image";
            const src = absUrl(
              mediaType === "video" ?
                (el.currentSrc || el.src || el.getAttribute("src")) :
                (el.currentSrc || el.src || el.getAttribute("src"))
            );
            if (!src || blockedAvatarLikeUrl(src)) return;

            let score = rect.width * rect.height;
            score += centerBonus(rect);
            if (mediaType === "video") score += 1500;
            if (src.includes("scontent")) score += 1000;
            if (src.includes("/stories/")) score += 500;

            candidates.push({
              score: score,
              mediaType: mediaType,
              src: src,
              width: Math.round(rect.width),
              height: Math.round(rect.height),
              poster: mediaType === "video" ? absUrl(el.poster || "") : ""
            });
          });

          candidates.sort((a, b) => b.score - a.score);
          const chosen = candidates[0];
          if (!chosen) return out;

          out.media_url = chosen.src;
          out.media_type = chosen.mediaType;
          out.width = chosen.width;
          out.height = chosen.height;
          if (chosen.mediaType === "video") {
            out.video_url = chosen.src;
            out.image_url = chosen.poster || "";
          } else {
            out.image_url = chosen.src;
            out.video_url = "";
          }
          return out;
        JS

        return nil unless payload.is_a?(Hash)

        media_url = payload["media_url"].to_s.presence
        return nil if media_url.blank?

        media_type = payload["media_type"].to_s
        {
          media_url: media_url,
          media_type: media_type.presence || "unknown",
          image_url: payload["image_url"].to_s,
          video_url: payload["video_url"].to_s,
          width: normalize_dom_story_media_dimension(payload["width"]),
          height: normalize_dom_story_media_dimension(payload["height"])
        }
      rescue StandardError
        nil
      end

      def normalize_dom_story_media_dimension(value)
        parsed = value.to_i
        parsed.positive? ? parsed : nil
      rescue StandardError
        nil
      end

      def resolve_story_item_via_performance_logs(driver:)
        return nil unless driver.respond_to?(:logs)

        types = driver.logs.available_types
        return nil unless types.include?(:performance) || types.include?("performance")

        perf_entries = Array(driver.logs.get(:performance))
        candidates = perf_entries.filter_map do |entry|
          raw = entry.respond_to?(:message) ? entry.message.to_s : entry.to_s
          next if raw.blank?

          parsed = JSON.parse(raw) rescue nil
          inner = parsed.is_a?(Hash) ? parsed["message"] : nil
          next unless inner.is_a?(Hash)
          next unless inner["method"].to_s == "Network.responseReceived"

          params = inner["params"].is_a?(Hash) ? inner["params"] : {}
          response = params["response"].is_a?(Hash) ? params["response"] : {}
          status = response["status"].to_i
          next unless status.between?(200, 299)

          url = normalize_story_media_url(response["url"].to_s)
          next if url.blank?
          next unless downloadable_story_media_url?(url)
          next unless url.include?("cdninstagram.com") || url.include?("fbcdn.net")

          mime_type = response["mimeType"].to_s.downcase
          media_type =
            if mime_type.start_with?("video/") || url.match?(/\.(mp4|mov|webm)(\?|$)/i)
              "video"
            elsif mime_type.start_with?("image/") || url.match?(/\.(jpg|jpeg|png|webp)(\?|$)/i)
              "image"
            else
              "unknown"
            end
          next if media_type == "unknown"

          {
            media_url: url,
            media_type: media_type,
            image_url: (media_type == "image" ? url : nil),
            video_url: (media_type == "video" ? url : nil),
            width: nil,
            height: nil
          }
        end

        candidates.reverse.find { |entry| entry[:media_url].to_s.present? }
      rescue StandardError
        nil
      end

      def resolve_story_item_via_api(username:, story_id:, cache: nil, driver: nil)
        uname = normalize_username(username)
        return nil if uname.blank?

        items = fetch_story_items_via_api(username: uname, cache: cache, driver: driver)
        return nil unless items.is_a?(Array)
        return nil if items.empty?

        sid = story_id.to_s.strip
        if sid.present?
          item = items.find { |s| s.is_a?(Hash) && s[:story_id].to_s == sid }
          return item if item
        end

        if sid.blank?
          visible_media_urls = resolve_visible_story_media_urls(driver: driver)
          if visible_media_urls.any?
            matched = items.find do |entry|
              story_item_media_urls(entry).any? { |url| media_url_matches_any?(url: url, candidates: visible_media_urls) }
            end
            return matched if matched.is_a?(Hash)
          end

          # Keep progress deterministic when Instagram uses /stories/:username/ without an id in URL.
          return items.first if items.first.is_a?(Hash)
        end

        nil
      rescue StandardError
        nil
      end

      def resolve_visible_story_media_urls(driver:)
        return [] unless driver

        dom_story = resolve_story_item_via_dom(driver: driver)
        perf_story = resolve_story_item_via_performance_logs(driver: driver)
        [
          dom_story.is_a?(Hash) ? dom_story[:media_url] : nil,
          dom_story.is_a?(Hash) ? dom_story[:image_url] : nil,
          dom_story.is_a?(Hash) ? dom_story[:video_url] : nil,
          perf_story.is_a?(Hash) ? perf_story[:media_url] : nil,
          perf_story.is_a?(Hash) ? perf_story[:image_url] : nil,
          perf_story.is_a?(Hash) ? perf_story[:video_url] : nil
        ].filter_map { |value| normalize_story_media_url(value.to_s) }.uniq
      rescue StandardError
        []
      end

      def story_item_media_urls(item)
        entry = item.is_a?(Hash) ? item : {}
        urls = [
          entry[:media_url],
          entry[:image_url],
          entry[:video_url]
        ]
        Array(entry[:media_variants]).each do |variant|
          next unless variant.is_a?(Hash)

          urls << variant[:media_url]
          urls << variant[:image_url]
          urls << variant[:video_url]
        end
        urls.filter_map { |value| normalize_story_media_url(value.to_s) }.uniq
      rescue StandardError
        []
      end

      def media_url_matches_any?(url:, candidates:)
        key = normalized_story_media_match_key(url)
        return false if key.blank?

        Array(candidates).any? do |candidate|
          normalized_story_media_match_key(candidate) == key
        end
      rescue StandardError
        false
      end

      def normalized_story_media_match_key(url)
        value = url.to_s.strip
        return "" if value.blank?

        parsed = URI.parse(value)
        host = parsed.host.to_s.downcase
        path = parsed.path.to_s
        return "" if host.blank? || path.blank?

        "#{host}#{path}"
      rescue StandardError
        value.split("?").first.to_s
      end

      def fetch_story_items_via_api(username:, cache: nil, driver: nil)
        uname = normalize_username(username)
        return [] if uname.blank?

        cache_key = "stories:#{uname}"
        if cache.is_a?(Hash) && cache[cache_key].is_a?(Hash)
          cached = cache[cache_key][:items]
          return cached if cached.is_a?(Array)
        end

        user_id = resolve_story_reel_user_id_for_username(username: uname, cache: cache, driver: driver)
        if user_id.blank?
          if cache.is_a?(Hash)
            cache[cache_key] = { user_id: nil, items: [], fetched_at: Time.current.utc.iso8601(3), error: "story_user_id_unavailable" }
          end
          return []
        end

        reel = fetch_story_reel(user_id: user_id, referer_username: uname, driver: driver)
        raw_items = reel.is_a?(Hash) ? Array(reel["items"]) : []
        stories = raw_items.filter_map { |item| extract_story_item(item, username: uname, reel_owner_id: user_id) }

        if cache.is_a?(Hash)
          cache[cache_key] = { user_id: user_id, items: stories, fetched_at: Time.current.utc.iso8601(3) }
        end
        stories
      rescue StandardError
        if cache.is_a?(Hash)
          cache[cache_key] = { user_id: nil, items: [], fetched_at: Time.current.utc.iso8601(3), error: "story_items_exception" }
        end
        []
      end

      def resolve_story_reel_user_id_for_username(username:, cache: nil, driver: nil)
        uname = normalize_username(username)
        return "" if uname.blank?

        cache_key = "stories:#{uname}"
        if cache.is_a?(Hash) && cache[cache_key].is_a?(Hash)
          cached_user_id = cache[cache_key][:user_id].to_s.strip
          return cached_user_id if cached_user_id.present?
        end

        tray_user_id = fetch_story_tray_user_id_map_via_api(cache: cache, driver: driver)[uname].to_s.strip
        return tray_user_id if tray_user_id.present?

        web_info = fetch_web_profile_info(uname, driver: driver)
        user = web_info.is_a?(Hash) ? web_info.dig("data", "user") : nil
        user.is_a?(Hash) ? user["id"].to_s.strip : ""
      rescue StandardError
        ""
      end

      def fetch_story_tray_user_id_map_via_api(cache: nil, driver: nil)
        cache_key = "stories:tray_user_ids"
        if cache.is_a?(Hash) && cache[cache_key].is_a?(Hash)
          return cache[cache_key]
        end

        body = ig_api_get_json(
          path: "/api/v1/feed/reels_tray/",
          referer: INSTAGRAM_BASE_URL,
          endpoint: "feed/reels_tray",
          username: @account.username,
          driver: driver,
          retries: 1
        )
        return {} unless body.is_a?(Hash)

        tray_items =
          if body["tray"].is_a?(Array)
            body["tray"]
          elsif body["tray"].is_a?(Hash)
            Array(body.dig("tray", "items"))
          else
            []
          end

        user_ids = {}
        tray_items.each do |item|
          next unless item.is_a?(Hash)

          user = item["user"].is_a?(Hash) ? item["user"] : item
          username = normalize_username(user["username"])
          next if username.blank?

          user_id = (
            user["id"] ||
            user["pk"] ||
            user["pk_id"] ||
            user["strong_id__"] ||
            item["id"] ||
            item["pk"]
          ).to_s.strip
          next if user_id.blank?

          user_ids[username] = user_id
        end

        cache[cache_key] = user_ids if cache.is_a?(Hash)
        user_ids
      rescue StandardError
        {}
      end

      def extract_story_item(item, username:, reel_owner_id: nil)
        return nil unless item.is_a?(Hash)

        story_id = (item["pk"] || item["id"]).to_s.split("_").first.to_s.strip
        return nil if story_id.blank?

        media_variants = extract_story_media_variants_from_item(item)
        selected_variant = choose_primary_story_media_variant(variants: media_variants)
        media_type = selected_variant[:media_type].to_s.presence || story_media_type(item["media_type"])
        image_url = selected_variant[:image_url].to_s.presence
        video_url = selected_variant[:video_url].to_s.presence
        media_url = selected_variant[:media_url].to_s.presence || video_url.presence || image_url.presence
        width = selected_variant[:width]
        height = selected_variant[:height]
        owner_id = (item.dig("owner", "id") || item.dig("owner", "pk") || item.dig("user", "id") || item.dig("user", "pk")).to_s.strip
        owner_username = normalize_username(item.dig("user", "username").to_s)
        external_story_ctx = detect_external_story_attribution_from_item(
          item: item,
          reel_owner_id: reel_owner_id.to_s.presence || owner_id,
          reel_username: username
        )

        {
          story_id: story_id,
          media_type: media_type,
          media_url: media_url.presence || image_url.presence || video_url.presence,
          image_url: image_url.presence,
          video_url: video_url.presence,
          can_reply: item.key?("can_reply") ? ActiveModel::Type::Boolean.new.cast(item["can_reply"]) : nil,
          can_reshare: item.key?("can_reshare") ? ActiveModel::Type::Boolean.new.cast(item["can_reshare"]) : nil,
          owner_user_id: owner_id.presence,
          owner_username: owner_username.presence,
          api_has_external_profile_indicator: external_story_ctx[:has_external_profile_indicator],
          api_external_profile_reason: external_story_ctx[:reason_code],
          api_external_profile_targets: external_story_ctx[:targets],
          api_should_skip: external_story_ctx[:has_external_profile_indicator],
          api_raw_media_type: item["media_type"].to_i,
          primary_media_source: selected_variant[:source].to_s.presence,
          primary_media_index: selected_variant[:index],
          media_variants: media_variants,
          carousel_media: media_variants.select { |entry| entry[:source].to_s == "carousel_media" },
          width: width.to_i.positive? ? width.to_i : nil,
          height: height.to_i.positive? ? height.to_i : nil,
          caption: item.dig("caption", "text").to_s.presence,
          taken_at: parse_unix_time(item["taken_at"] || item["taken_at_timestamp"]),
          expiring_at: parse_unix_time(item["expiring_at"] || item["expiring_at_timestamp"]),
          permalink: "#{INSTAGRAM_BASE_URL}/stories/#{username}/#{story_id}/"
        }
      rescue StandardError
        nil
      end

      def extract_story_media_variants_from_item(item)
        return [] unless item.is_a?(Hash)

        variants = []
        variants << build_story_media_variant(item: item, source: "root", index: 0)
        Array(item["carousel_media"]).each_with_index do |entry, idx|
          variants << build_story_media_variant(item: entry, source: "carousel_media", index: idx + 1)
        end
        variants.compact.select { |entry| entry[:media_url].to_s.present? }
      rescue StandardError
        []
      end

      def build_story_media_variant(item:, source:, index:)
        return nil unless item.is_a?(Hash)

        media_type = story_media_type(item["media_type"])
        image_candidate = item.dig("image_versions2", "candidates", 0)
        video_candidate = Array(item["video_versions"]).first
        image_url = normalize_story_media_url(CGI.unescapeHTML(image_candidate&.dig("url").to_s).strip)
        video_url = normalize_story_media_url(CGI.unescapeHTML(video_candidate&.dig("url").to_s).strip)
        media_url = media_type == "video" ? (video_url.presence || image_url.presence) : (image_url.presence || video_url.presence)
        width = item["original_width"] || image_candidate&.dig("width") || video_candidate&.dig("width")
        height = item["original_height"] || image_candidate&.dig("height") || video_candidate&.dig("height")

        {
          source: source.to_s,
          index: index.to_i,
          media_pk: (item["pk"] || item["id"]).to_s.split("_").first.to_s.presence,
          raw_media_type: item["media_type"].to_i,
          media_type: media_type,
          media_url: media_url.to_s.presence,
          image_url: image_url,
          video_url: video_url,
          width: width.to_i.positive? ? width.to_i : nil,
          height: height.to_i.positive? ? height.to_i : nil
        }
      rescue StandardError
        nil
      end

      def choose_primary_story_media_variant(variants:)
        list = Array(variants).select { |entry| entry.is_a?(Hash) && entry[:media_url].to_s.present? }
        return {} if list.empty?

        root = list.find { |entry| entry[:source].to_s == "root" }
        return root if root

        video = list.find { |entry| entry[:media_type].to_s == "video" }
        return video if video

        list.first
      rescue StandardError
        {}
      end

      def normalize_story_media_url(url)
        value = url.to_s.strip
        return nil if value.blank?
        return value if value.start_with?("http://", "https://")
        return nil if value.start_with?("data:")
        return nil if value.match?(/\A[a-z][a-z0-9+\-.]*:/i)

        URI.join(INSTAGRAM_BASE_URL, value).to_s
      rescue URI::InvalidURIError, ArgumentError
        nil
      end

      def downloadable_story_media_url?(url)
        value = url.to_s.strip
        return false if value.blank?
        return false unless value.start_with?("http://", "https://")

        uri = URI.parse(value)
        uri.is_a?(URI::HTTP) || uri.is_a?(URI::HTTPS)
      rescue URI::InvalidURIError, ArgumentError
        false
      end

      def compact_story_media_variants_for_metadata(variants, limit: 8)
        Array(variants).first(limit.to_i.clamp(1, 20)).filter_map do |entry|
          data = entry.is_a?(Hash) ? entry : {}
          source = data[:source] || data["source"]
          media_type = data[:media_type] || data["media_type"]
          media_url = data[:media_url] || data["media_url"]
          next nil if media_url.to_s.blank?

          {
            source: source.to_s.presence,
            index: data[:index] || data["index"],
            media_pk: (data[:media_pk] || data["media_pk"]).to_s.presence,
            media_type: media_type.to_s.presence,
            media_url: media_url.to_s.presence,
            image_url: (data[:image_url] || data["image_url"]).to_s.presence,
            video_url: (data[:video_url] || data["video_url"]).to_s.presence,
            width: data[:width] || data["width"],
            height: data[:height] || data["height"]
          }.compact
        end
      rescue StandardError
        []
      end

      def detect_external_story_attribution_from_item(item:, reel_owner_id:, reel_username:)
        return { has_external_profile_indicator: false, reason_code: nil, targets: [] } unless item.is_a?(Hash)

        reasons = []
        targets = []
        normalized_owner_username = normalize_username(reel_username)

        owner_id = (item.dig("owner", "id") || item.dig("owner", "pk")).to_s.strip
        if owner_id.present? && reel_owner_id.to_s.present? && owner_id != reel_owner_id.to_s
          reasons << "owner_id_mismatch"
          targets << owner_id
        end

        story_feed_media = Array(item["story_feed_media"])
        if story_feed_media.any?
          sfm_targets = extract_story_feed_media_targets(story_feed_media)
          sfm_external_targets = sfm_targets.select do |target|
            external_story_target?(target, reel_owner_id: reel_owner_id, reel_username: normalized_owner_username)
          end
          if sfm_external_targets.any?
            reasons << "story_feed_media_external"
            targets.concat(sfm_external_targets)
          end
        end

        media_attribution_targets = extract_media_attribution_targets(Array(item["media_attributions_data"]))
        external_media_attribution_targets = media_attribution_targets.select do |target|
          external_story_target?(target, reel_owner_id: reel_owner_id, reel_username: normalized_owner_username)
        end
        if external_media_attribution_targets.any?
          reasons << "media_attributions_external"
          targets.concat(external_media_attribution_targets)
        end

        mention_targets = extract_reel_mention_targets(Array(item["reel_mentions"]))
        external_mention_targets = mention_targets.select do |target|
          external_story_target?(target, reel_owner_id: reel_owner_id, reel_username: normalized_owner_username)
        end
        if external_mention_targets.any?
          reasons << "reel_mentions_external"
          targets.concat(external_mention_targets)
        end

        reasons << "reshare_of_text_post" if item["is_reshare_of_text_post_app_media_in_ig"] == true

        owner_username = normalize_username(item.dig("user", "username").to_s)
        if owner_username.present? && normalized_owner_username.present? && owner_username != normalized_owner_username
          reasons << "owner_username_mismatch"
          targets << owner_username
        end

        reason_codes = reasons.uniq
        {
          has_external_profile_indicator: reason_codes.any?,
          reason_code: reason_codes.first,
          targets: targets.map(&:to_s).map(&:strip).reject(&:blank?).uniq.first(12)
        }
      rescue StandardError
        { has_external_profile_indicator: false, reason_code: nil, targets: [] }
      end

      def external_story_target?(target, reel_owner_id:, reel_username:)
        value = target.to_s.strip
        return false if value.blank?

        if value.match?(/\A\d+\z/)
          owner_id = reel_owner_id.to_s.strip
          return false if owner_id.blank?
          return value != owner_id
        end

        owner_username = normalize_username(reel_username)
        normalized_value = normalize_username(value)
        return false if owner_username.blank? || normalized_value.blank?

        normalized_value != owner_username
      rescue StandardError
        false
      end

      def extract_story_feed_media_targets(story_feed_media)
        Array(story_feed_media).filter_map do |entry|
          next unless entry.is_a?(Hash)

          media_owner_id = (
            entry.dig("media", "user", "id") ||
            entry.dig("media", "user", "pk") ||
            entry.dig("user", "id") ||
            entry.dig("user", "pk")
          ).to_s.strip
          next media_owner_id if media_owner_id.present?

          media_owner_username = normalize_username(
            entry.dig("media", "user", "username").to_s.presence ||
            entry.dig("user", "username").to_s
          )
          next media_owner_username if media_owner_username.present?

          compound = entry["media_compound_str"].to_s.strip
          next "" if compound.blank?
          next "" unless compound.include?("_")

          compound.split("_")[1].to_s.strip
        end.reject(&:blank?)
      rescue StandardError
        []
      end

      def extract_reel_mention_targets(reel_mentions)
        Array(reel_mentions).filter_map do |mention|
          next unless mention.is_a?(Hash)

          user_id = (mention.dig("user", "id") || mention.dig("user", "pk") || mention["user_id"]).to_s.strip
          next user_id if user_id.present?

          username = normalize_username(mention.dig("user", "username").to_s.presence || mention["username"].to_s)
          next username if username.present?

          nil
        end
      rescue StandardError
        []
      end

      def extract_media_attribution_targets(media_attributions_data)
        targets = []
        Array(media_attributions_data).each do |entry|
          collect_candidate_user_targets(entry, targets)
        end
        targets.map(&:to_s).map(&:strip).reject(&:blank?).uniq
      rescue StandardError
        []
      end

      def collect_candidate_user_targets(node, targets)
        return if node.nil?

        if node.is_a?(Array)
          node.each { |child| collect_candidate_user_targets(child, targets) }
          return
        end

        return unless node.is_a?(Hash)

        username_keys = %w[username owner_username mentioned_username]
        id_keys = %w[user_id owner_id mentioned_user_id pk id]

        username_keys.each do |key|
          value = normalize_username(node[key].to_s)
          targets << value if value.present?
        end
        id_keys.each do |key|
          value = node[key].to_s.strip
          targets << value if value.match?(/\A\d+\z/)
        end

        node.each_value { |child| collect_candidate_user_targets(child, targets) if child.is_a?(Hash) || child.is_a?(Array) }
      end

      def story_media_type(value)
        case value.to_i
        when 2 then "video"
        else "image"
        end
      end

      def remember_story_api_failure!(endpoint:, url:, status:, username:, user_id: nil, reason: nil, response_snippet: nil, retry_after_seconds: nil, headers: nil)
        @story_api_recent_failures ||= {}
        retry_window = retry_after_seconds.to_i
        reason_value = reason.to_s.strip
        payload = {
          endpoint: endpoint.to_s,
          url: url.to_s.presence,
          status: status.to_i,
          rate_limited: status.to_i == 429,
          username: normalize_username(username),
          user_id: user_id.to_s.presence,
          reason: reason_value.presence,
          useragent_mismatch: ig_useragent_mismatch_failure?(reason: reason_value, response_snippet: response_snippet),
          response_snippet: response_snippet.to_s.byteslice(0, 300),
          retry_after_seconds: retry_window.positive? ? retry_window : nil,
          rate_limit_headers: headers.is_a?(Hash) ? headers : nil,
          occurred_at_epoch: Time.current.to_i
        }.compact
        return if payload[:status].to_i <= 0

        @story_api_recent_failures[payload[:username]] = payload if payload[:username].present?
        @story_api_recent_failures[:global] = payload
      rescue StandardError
        nil
      end

      def story_api_recent_failure_for(username:)
        failures = @story_api_recent_failures
        return nil unless failures.is_a?(Hash)

        uname = normalize_username(username)
        payload = uname.present? ? failures[uname] : nil
        payload ||= failures[:global]
        return nil unless payload.is_a?(Hash)

        occurred_at_epoch = payload[:occurred_at_epoch].to_i
        return nil if occurred_at_epoch <= 0
        retry_after_seconds = payload[:retry_after_seconds].to_i
        if retry_after_seconds.positive?
          return nil if Time.at(occurred_at_epoch) + retry_after_seconds.seconds < Time.current
        else
          return nil if Time.at(occurred_at_epoch) < 10.minutes.ago
        end

        payload
      rescue StandardError
        nil
      end

      def story_api_rate_limited_for?(username:)
        payload = story_api_recent_failure_for(username: username)
        ActiveModel::Type::Boolean.new.cast(payload&.dig(:rate_limited))
      rescue StandardError
        false
      end

      def ig_useragent_mismatch_failure?(reason:, response_snippet:)
        content = "#{reason} #{response_snippet}".downcase
        content.include?("useragent mismatch") || content.include?("user agent mismatch")
      rescue StandardError
        false
      end

      def extract_ig_rate_limit_headers(response)
        return {} unless response.respond_to?(:each_header)

        keys = %w[
          retry-after
          x-ratelimit-limit
          x-ratelimit-remaining
          x-ratelimit-reset
          x-ig-ratelimit-limit
          x-ig-ratelimit-remaining
          x-ig-ratelimit-reset
        ]
        result = {}
        response.each_header do |name, value|
          key = name.to_s.downcase
          next unless keys.include?(key)

          result[key] = value.to_s
        end
        result
      rescue StandardError
        {}
      end

      def resolve_ig_api_retry_delay_seconds(failure:, attempt:)
        retry_after_header = failure.dig(:headers, "retry-after").to_s
        retry_after_seconds = parse_retry_after_seconds(retry_after_header)
        return retry_after_seconds if retry_after_seconds.positive?

        status = failure[:status].to_i
        base = status == 429 ? 2.0 : 0.6
        jitter = rand * 0.4
        exponent = [ [ attempt.to_i - 1, 0 ].max, 4 ].min
        [ (base * (2 ** exponent)) + jitter, 45.0 ].min
      rescue StandardError
        1.0
      end

      def parse_retry_after_seconds(raw)
        value = raw.to_s.strip
        return 0 if value.blank?

        numeric = Integer(value, exception: false)
        return numeric.to_i.clamp(0, 7200) if numeric

        parsed = Time.httpdate(value) rescue nil
        return 0 unless parsed

        [ (parsed - Time.now).ceil, 0 ].max.clamp(0, 7200)
      rescue StandardError
        0
      end

      def ig_api_endpoint_pause_key(endpoint:, username:)
        uname = normalize_username(username).presence || "global"
        ep = endpoint.to_s.presence || "unknown"
        "#{IG_API_RATE_LIMIT_CACHE_PREFIX}:account:#{@account.id}:#{uname}:#{ep}"
      end

      def ig_api_endpoint_paused?(endpoint:, username:)
        key = ig_api_endpoint_pause_key(endpoint: endpoint, username: username)
        payload = Rails.cache.read(key)
        return nil unless payload.is_a?(Hash)

        unblock_at = Time.zone.parse(payload["unblock_at"].to_s) rescue nil
        return nil if unblock_at.blank? || unblock_at <= Time.current

        {
          reason: payload["reason"].to_s.presence || "local_rate_limit_pause",
          retry_after_seconds: [ (unblock_at - Time.current).ceil, 0 ].max,
          headers: payload["headers"].is_a?(Hash) ? payload["headers"] : {}
        }
      rescue StandardError
        nil
      end

      def apply_ig_api_rate_limit_state!(endpoint:, uri:, username:, status:, headers:, reason:)
        status_i = status.to_i
        return if status_i <= 0

        headers_hash = headers.is_a?(Hash) ? headers : {}
        retry_after_seconds = parse_retry_after_seconds(headers_hash["retry-after"].to_s)
        if status_i == 429 && retry_after_seconds <= 0
          retry_after_seconds = 30
        elsif status_i >= 500 && retry_after_seconds <= 0
          retry_after_seconds = 5
        end
        return if retry_after_seconds <= 0

        unblock_at = Time.current + retry_after_seconds.seconds
        key = ig_api_endpoint_pause_key(endpoint: endpoint, username: username)
        Rails.cache.write(
          key,
          {
            "unblock_at" => unblock_at.iso8601,
            "reason" => reason.to_s.presence || "http_#{status_i}",
            "status" => status_i,
            "headers" => headers_hash
          },
          expires_in: [ retry_after_seconds + 15, 90.minutes ].min.seconds
        )

        remember_story_api_failure!(
          endpoint: endpoint.to_s.presence || "unknown",
          url: uri.to_s,
          status: status_i,
          username: username,
          response_snippet: nil,
          retry_after_seconds: retry_after_seconds,
          headers: headers_hash
        )

        Ops::StructuredLogger.warn(
          event: "instagram.api.rate_limit_pause",
          payload: {
            endpoint: endpoint.to_s.presence || "unknown",
            url: uri.to_s,
            status: status_i,
            username: normalize_username(username).presence,
            retry_after_seconds: retry_after_seconds,
            headers: headers_hash.presence
          }.compact
        )
      rescue StandardError
        nil
      end

      def endpoint_request_spacing_seconds(endpoint)
        ep = endpoint.to_s
        return 0.7 if ep.include?("direct_v2")
        return 0.45 if ep.include?("feed/reels_media")
        return 0.35 if ep.include?("users/web_profile_info")

        0.2
      end

      def apply_ig_api_request_spacing!(endpoint:, username:)
        spacing = endpoint_request_spacing_seconds(endpoint)
        return if spacing <= 0

        uname = normalize_username(username).presence || "global"
        ep = endpoint.to_s.presence || "unknown"
        key = "#{IG_API_RATE_LIMIT_CACHE_PREFIX}:spacing:account:#{@account.id}:#{uname}:#{ep}"
        now = Time.current.to_f
        next_allowed = Rails.cache.read(key).to_f
        if next_allowed > now
          sleep([next_allowed - now, 1.2].min)
        end

        Rails.cache.write(key, Time.current.to_f + spacing, expires_in: 90.seconds)
      rescue StandardError
        nil
      end

      def record_ig_api_usage!(endpoint:, username:, method:, status:)
        minute_bucket = Time.current.utc.strftime("%Y%m%d%H%M")
        uname = normalize_username(username).presence || "global"
        ep = endpoint.to_s.presence || "unknown"
        key = "#{IG_API_USAGE_CACHE_PREFIX}:#{minute_bucket}:account:#{@account.id}:#{uname}:#{method}:#{ep}:#{status.to_i}"
        current = Rails.cache.read(key).to_i
        Rails.cache.write(key, current + 1, expires_in: 90.minutes)
      rescue StandardError
        nil
      end

      def debug_story_reel_data(referer_username:, user_id:, body:)
        begin
          # Create debug directory if it doesn't exist
          debug_dir = Rails.root.join("tmp", "story_reel_debug")
          FileUtils.mkdir_p(debug_dir) unless Dir.exist?(debug_dir)

          # Generate filename with timestamp
          timestamp = Time.current.strftime("%Y%m%d_%H%M%S_%L")
          filename = "#{referer_username}_reel_#{user_id}_#{timestamp}.json"
          filepath = File.join(debug_dir, filename)

          # Extract relevant debug information
          debug_data = {
            timestamp: Time.current.iso8601,
            referer_username: referer_username,
            user_id: user_id,
            raw_response: body,
            reels_count: body["reels"]&.keys&.size || 0,
            reels_media_count: body["reels_media"]&.size || 0,
            items_count: extract_items_count_from_body(body)
          }

          # Write debug data to file
          File.write(filepath, JSON.pretty_generate(debug_data))

          # Log the debug file creation
          Rails.logger.info "[STORY_REEL_DEBUG] Debug data saved: #{filepath}"

        rescue StandardError => e
          Rails.logger.error "[STORY_REEL_DEBUG] Failed to capture debug data: #{e.message}"
          # Don't fail the entire request if debug capture fails
        end
      end

      def extract_items_count_from_body(body)
        items = []
      
        if body["reels"].is_a?(Hash)
          body["reels"].each do |reel_id, reel_data|
            if reel_data.is_a?(Hash) && reel_data["items"].is_a?(Array)
              items.concat(reel_data["items"])
            end
          end
        end
      
        if body["reels_media"].is_a?(Array)
          body["reels_media"].each do |reel_data|
            if reel_data.is_a?(Hash) && reel_data["items"].is_a?(Array)
              items.concat(reel_data["items"])
            end
          end
        end
      
        items.size
      end

      def reel_entry_owner_id(entry)
        return "" unless entry.is_a?(Hash)

        (
          entry.dig("user", "id") ||
          entry.dig("user", "pk") ||
          entry.dig("owner", "id") ||
          entry.dig("owner", "pk") ||
          entry["id"] ||
          entry["pk"]
        ).to_s.strip
      rescue StandardError
        ""
      end

      def extract_post_for_analysis(item, comments_limit:, referer_username:)
        return nil unless item.is_a?(Hash)

        media_type = item["media_type"].to_i
        product_type = item["product_type"].to_s.downcase
        post_kind = product_type.include?("clips") ? "reel" : "post"
        is_repost =
          ActiveModel::Type::Boolean.new.cast(item["is_repost"]) ||
          item.dig("reshared_content", "pk").present? ||
          item["reshare_count"].to_i.positive?
        image_url = nil
        video_url = nil

        if media_type == 1
          image_url = item.dig("image_versions2", "candidates", 0, "url").to_s
        elsif media_type == 2
          video_url = Array(item["video_versions"]).first&.dig("url").to_s
          image_url = item.dig("image_versions2", "candidates", 0, "url").to_s
        elsif media_type == 8
          carousel = Array(item["carousel_media"]).select { |m| m.is_a?(Hash) }
          vid = carousel.find { |m| m["media_type"].to_i == 2 }
          img = carousel.find { |m| m["media_type"].to_i == 1 }
          video_url = Array(vid&.dig("video_versions")).first&.dig("url").to_s
          image_url = vid&.dig("image_versions2", "candidates", 0, "url").to_s.presence || img&.dig("image_versions2", "candidates", 0, "url").to_s
        else
          return nil
        end

        image_url = CGI.unescapeHTML(image_url).strip
        video_url = CGI.unescapeHTML(video_url).strip
        media_url = video_url.presence || image_url.presence
        return nil if media_url.blank?

        media_pk = item["pk"].presence || item["id"].to_s.split("_").first
        comments = fetch_media_comments(media_id: media_pk, referer_username: referer_username, count: comments_limit)
        comments = extract_preview_comments(item, comments_limit: comments_limit) if comments.empty?

        taken_at = parse_unix_time(item["taken_at"])
        shortcode = (item["code"] || item["shortcode"]).to_s.strip.presence
        permalink = shortcode.present? ? "#{INSTAGRAM_BASE_URL}/p/#{shortcode}/" : nil

        {
          shortcode: shortcode,
          media_id: media_pk.to_s.presence,
          post_kind: post_kind,
          product_type: product_type.presence,
          is_repost: is_repost,
          taken_at: taken_at,
          caption: item.dig("caption", "text").to_s.presence,
          media_url: media_url,
          image_url: image_url,
          video_url: video_url.presence,
          media_type: media_type,
          permalink: permalink,
          likes_count: item["like_count"].to_i,
          comments_count: item["comment_count"].to_i,
          comments: comments
        }
      rescue StandardError
        nil
      end

      def extract_preview_comments(item, comments_limit:)
        Array(item["preview_comments"]).first(comments_limit).map do |c|
          {
            author_username: c.is_a?(Hash) ? c.dig("user", "username").to_s.strip : nil,
            text: c.is_a?(Hash) ? c["text"].to_s : nil,
            created_at: parse_unix_time(c.is_a?(Hash) ? c["created_at"] : nil)
          }
        end
      end

      def fetch_media_comments(media_id:, referer_username:, count:)
        return [] if media_id.to_s.blank?

        uri = URI.parse("#{INSTAGRAM_BASE_URL}/api/v1/media/#{media_id}/comments/?can_support_threading=true&permalink_enabled=true")

        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = (uri.scheme == "https")
        http.open_timeout = 10
        http.read_timeout = 20

        req = Net::HTTP::Get.new(uri.request_uri)
        req["User-Agent"] = @account.user_agent.presence || "Mozilla/5.0"
        req["Accept"] = "application/json, text/plain, */*"
        req["X-Requested-With"] = "XMLHttpRequest"
        req["X-IG-App-ID"] = ig_api_app_id_header_value
        ig_www_claim = ig_www_claim_header_value
        req["X-IG-WWW-Claim"] = ig_www_claim if ig_www_claim.present?
        req["Referer"] = "#{INSTAGRAM_BASE_URL}/#{referer_username}/"

        csrf = @account.cookies.find { |c| c["name"].to_s == "csrftoken" }&.dig("value").to_s
        req["X-CSRFToken"] = csrf if csrf.present?
        req["Cookie"] = cookie_header_for(@account.cookies)

        res = http.request(req)
        return [] unless res.is_a?(Net::HTTPSuccess)
        return [] unless res["content-type"].to_s.include?("json")

        body = JSON.parse(res.body.to_s)
        items = Array(body["comments"]).first(count.to_i.clamp(1, 50))
        items.map do |c|
          {
            author_username: c.dig("user", "username").to_s.strip.presence,
            text: c["text"].to_s,
            created_at: parse_unix_time(c["created_at"])
          }
        end
      rescue StandardError
        []
      end

      def enrich_missing_post_comments_via_browser!(username:, posts:, comments_limit:)
        target_posts = Array(posts).select do |post|
          post.is_a?(Hash) &&
            post[:media_id].to_s.present? &&
            post[:comments_count].to_i.positive? &&
            Array(post[:comments]).empty?
        end
        return if target_posts.empty?

        with_recoverable_session(label: "profile_analysis_comments_fallback") do
          with_authenticated_driver do |driver|
            driver.navigate.to("#{INSTAGRAM_BASE_URL}/#{username}/")
            wait_for(driver, css: "body", timeout: 10)
            dismiss_common_overlays!(driver)

            target_posts.each do |post|
              comments = fetch_media_comments_from_browser_context(
                driver: driver,
                media_id: post[:media_id],
                count: comments_limit
              )
              next if comments.empty?

              post[:comments] = comments
            rescue StandardError
              next
            end
          end
        end
      rescue StandardError
        nil
      end

      def fetch_media_comments_from_browser_context(driver:, media_id:, count:)
        payload =
          driver.execute_async_script(
            <<~JS,
              const mediaId = arguments[0];
              const limit = arguments[1];
              const done = arguments[arguments.length - 1];

              fetch(`/api/v1/media/${mediaId}/comments/?can_support_threading=true&permalink_enabled=true`, {
                method: "GET",
                credentials: "include",
                headers: {
                  "Accept": "application/json, text/plain, */*",
                  "X-Requested-With": "XMLHttpRequest"
                }
              })
                .then(async (resp) => {
                  const text = await resp.text();
                  done({
                    ok: resp.ok,
                    status: resp.status,
                    content_type: resp.headers.get("content-type") || "",
                    body: text
                  });
                })
                .catch((err) => {
                  done({ ok: false, status: 0, content_type: "", body: "", error: String(err) });
                });
            JS
            media_id.to_s,
            count.to_i.clamp(1, 50)
          )

        return [] unless payload.is_a?(Hash)
        return [] unless payload["ok"] == true
        return [] unless payload["content_type"].to_s.include?("json")

        body = JSON.parse(payload["body"].to_s)
        items = Array(body["comments"]).first(count.to_i.clamp(1, 50))
        items.map do |c|
          {
            author_username: c.dig("user", "username").to_s.strip.presence,
            text: c["text"].to_s,
            created_at: parse_unix_time(c["created_at"])
          }
        end
      rescue StandardError
        []
      end
    end
  end
end
