module Instagram
  class Client
    module StorySignalSupport
      private

      def evaluate_story_image_quality(download:, media:)
        bytes = download.is_a?(Hash) ? download[:bytes].to_s.b : "".b
        content_type = download.is_a?(Hash) ? download[:content_type].to_s : ""
        width = media[:width].to_i
        height = media[:height].to_i

        return { skip: true, reason: "empty_download", entropy: nil } if bytes.blank?
        return { skip: true, reason: "too_small_bytes", entropy: nil } if bytes.bytesize < 1500
        return { skip: true, reason: "tiny_dimensions", entropy: nil } if width.positive? && height.positive? && (width < 120 || height < 120)

        entropy = bytes_entropy(bytes)

        # Heuristic: placeholder/blank assets are often very small and very low entropy.
        if content_type.start_with?("image/") && bytes.bytesize < 45_000 && entropy < 4.2
          return { skip: true, reason: "low_entropy_small_image", entropy: entropy }
        end

        { skip: false, reason: nil, entropy: entropy }
      rescue StandardError
        { skip: false, reason: nil, entropy: nil }
      end

      def bytes_entropy(bytes)
        data = bytes.to_s.b
        return 0.0 if data.empty?

        counts = Array.new(256, 0)
        data.each_byte { |b| counts[b] += 1 }

        len = data.bytesize.to_f
        entropy = 0.0
        counts.each do |count|
          next if count.zero?

          p = count / len
          entropy -= p * Math.log2(p)
        end
        entropy.round(4)
      end

      def detect_story_ad_context(driver:, media: nil)
        payload = driver.execute_script(<<~JS)
          const out = { ad_detected: false, reason: "", marker_text: "" };
          const explicitMarkers = [
            "sponsored",
            "sponsored post",
            "sponsored content",
            "promoted",
            "paid partnership",
            "advertisement"
          ];
          const norm = (value) => (value || "").toString().replace(/\\s+/g, " ").trim().toLowerCase();
          const isVisible = (el) => {
            if (!el) return false;
            const s = window.getComputedStyle(el);
            if (!s || s.display === "none" || s.visibility === "hidden" || s.opacity === "0") return false;
            const r = el.getBoundingClientRect();
            if (r.width < 4 || r.height < 4) return false;
            return r.bottom > 0 && r.top < window.innerHeight;
          };
          const inStoryHeaderZone = (el) => {
            const r = el.getBoundingClientRect();
            return r.top >= 0 && r.top <= Math.max(240, window.innerHeight * 0.38);
          };
          const matchesExplicitMarker = (text) => {
            if (!text) return "";
            for (const m of explicitMarkers) {
              if (text === m) return m;
              if (text.startsWith(`${m} `)) return m;
              if (text.endsWith(` ${m}`)) return m;
              if (text.includes(` ${m} `)) return m;
            }
            return "";
          };
          const markerRegex = /\b(sponsored|promoted|paid partnership|advertisement)\b/;

          const path = (window.location && window.location.pathname || "").toLowerCase();
          if (!path.includes("/stories/")) return out;

          // Keep the search focused on story header text nodes to avoid false positives from unrelated controls.
          const nodes = Array.from(document.querySelectorAll("header span, header a, header [role='button'], [data-testid*='story'] span, [data-testid*='story'] a"));
          for (const node of nodes) {
            if (!isVisible(node)) continue;
            if (!inStoryHeaderZone(node)) continue;

            const text = norm(node.innerText || node.textContent);
            const aria = norm(node.getAttribute && node.getAttribute("aria-label"));
            if (text.length > 60 && aria.length > 60) continue;

            const marker = matchesExplicitMarker(text) || matchesExplicitMarker(aria);
            if (!marker) continue;

            out.ad_detected = true;
            out.reason = "header_marker_match";
            out.marker_text = text || aria || marker;
            return out;
          }

          // Backup detector: scan concise visible labels in the top story zone.
          // This catches some sponsored labels that are not rendered inside <header>.
          const topNodes = Array.from(document.querySelectorAll("span, a, div, button")).filter((node) => {
            if (!isVisible(node)) return false;
            if (!inStoryHeaderZone(node)) return false;
            const text = norm(node.innerText || node.textContent);
            if (!text || text.length > 42) return false;
            return true;
          });

          for (const node of topNodes) {
            const text = norm(node.innerText || node.textContent);
            const aria = norm(node.getAttribute && node.getAttribute("aria-label"));
            const title = norm(node.getAttribute && node.getAttribute("title"));
            const candidate = [text, aria, title].find((value) => value && markerRegex.test(value));
            if (!candidate) continue;

            out.ad_detected = true;
            out.reason = "top_zone_marker_match";
            out.marker_text = candidate;
            return out;
          }

          return out;
        JS

        return { ad_detected: false, reason: "", marker_text: "", signal_source: "", signal_confidence: "", debug_hint: "" } unless payload.is_a?(Hash)

        result = {
          ad_detected: ActiveModel::Type::Boolean.new.cast(payload["ad_detected"]),
          reason: payload["reason"].to_s,
          marker_text: payload["marker_text"].to_s,
          signal_source: "dom_header",
          signal_confidence: "high",
          debug_hint: ""
        }
        return result if result[:ad_detected]

        media_url = media.is_a?(Hash) ? media[:url].to_s : ""
        media_hint = ad_hint_from_media_url(media_url)
        return result.merge(signal_source: "", signal_confidence: "", debug_hint: "") if media_hint.blank?

        if media_hint[:confidence] == "high"
          {
            ad_detected: true,
            reason: "media_url_ad_marker",
            marker_text: media_hint[:marker].to_s,
            signal_source: "media_url",
            signal_confidence: media_hint[:confidence].to_s,
            debug_hint: media_hint[:marker].to_s
          }
        else
          {
            ad_detected: false,
            reason: "",
            marker_text: "",
            signal_source: "media_url",
            signal_confidence: media_hint[:confidence].to_s,
            debug_hint: media_hint[:marker].to_s
          }
        end
      rescue StandardError
        { ad_detected: false, reason: "", marker_text: "", signal_source: "", signal_confidence: "", debug_hint: "" }
      end

      def detect_story_external_profile_link_context(driver:, current_username:)
        current = normalize_username(current_username).to_s
        payload = driver.execute_script(<<~JS, current)
          const currentUsername = (arguments[0] || "").toString().trim().toLowerCase();
          const out = { has_external_profile_link: false, linked_username: "", linked_profile_url: "", marker_text: "" };
          const norm = (value) => (value || "").toString().replace(/\\s+/g, " ").trim();
          const normLower = (value) => norm(value).toLowerCase();
          const isVisible = (el) => {
            if (!el) return false;
            const s = window.getComputedStyle(el);
            if (!s || s.display === "none" || s.visibility === "hidden" || s.opacity === "0") return false;
            const r = el.getBoundingClientRect();
            if (r.width < 8 || r.height < 8) return false;
            return r.bottom > 0 && r.top < window.innerHeight;
          };
          const parseLinkedUsername = (href) => {
            try {
              const u = new URL(href, window.location.origin);
              if (!/instagram\\.com$/i.test(u.hostname)) return "";
              const segs = u.pathname.split("/").filter(Boolean);
              if (segs.length !== 1) return "";
              const candidate = (segs[0] || "").toLowerCase();
              if (!/^[a-z0-9._]{1,30}$/.test(candidate)) return "";
              return candidate;
            } catch (e) {
              return "";
            }
          };

          const candidates = Array.from(document.querySelectorAll("a[href], [role='link'][href], [role='link'][data-href]"));
          for (const el of candidates) {
            if (!isVisible(el)) continue;
            const href = (el.getAttribute("href") || el.getAttribute("data-href") || "").toString();
            if (!href) continue;
            const linked = parseLinkedUsername(href);
            if (!linked) continue;
            if (linked === currentUsername) continue;

            const text = norm(el.innerText || el.textContent);
            const aria = norm(el.getAttribute && el.getAttribute("aria-label"));
            const title = norm(el.getAttribute && el.getAttribute("title"));
            const marker = [text, aria, title].find((v) => v && v.length > 0) || linked;
            const markerLower = normLower(marker);

            // Ignore common mention-style links; they do not necessarily indicate reshared content.
            if (markerLower.startsWith("@")) continue;
            if (markerLower.includes("mention")) continue;

            out.has_external_profile_link = true;
            out.linked_username = linked;
            out.linked_profile_url = href;
            out.marker_text = marker;
            return out;
          }

          return out;
        JS

        return { has_external_profile_link: false, linked_username: "", linked_profile_url: "", marker_text: "" } unless payload.is_a?(Hash)

        {
          has_external_profile_link: ActiveModel::Type::Boolean.new.cast(payload["has_external_profile_link"]),
          linked_username: payload["linked_username"].to_s,
          linked_profile_url: payload["linked_profile_url"].to_s,
          marker_text: payload["marker_text"].to_s
        }
      rescue StandardError
        { has_external_profile_link: false, linked_username: "", linked_profile_url: "", marker_text: "" }
      end

      def ad_hint_from_media_url(url)
        value = url.to_s.strip
        return nil if value.blank?

        down = value.downcase
        return { marker: "_nc_ad_query", confidence: "low" } if down.include?("_nc_ad=")
        return { marker: "ad_image_marker", confidence: "high" } if down.include?("ad_image")
        return { marker: "ads_image_marker", confidence: "high" } if down.include?("ads_image")
        return { marker: "ad_urlgen_marker", confidence: "high" } if down.include?("ad_urlgen")
        return { marker: "page_instagram_web_story_marker", confidence: "low" } if down.include?("page_instagram_web_story")

        uri = URI.parse(value)
        query = Rack::Utils.parse_query(uri.query.to_s)
        raw_efg = query["efg"].to_s
        return nil if raw_efg.blank?

        decoded = decode_urlsafe_base64(raw_efg)
        return nil if decoded.blank?

        text = decoded.downcase
        return { marker: "efg_ad_image", confidence: "high" } if text.include?("ad_image")
        return { marker: "efg_ads_image", confidence: "high" } if text.include?("ads_image")
        return { marker: "efg_ad_urlgen", confidence: "high" } if text.include?("ad_urlgen")
        return { marker: "efg_page_instagram_web_story", confidence: "low" } if text.include?("page_instagram_web_story")

        nil
      rescue StandardError
        nil
      end

      def decode_urlsafe_base64(value)
        src = value.to_s.tr("-_", "+/")
        src += "=" * ((4 - (src.length % 4)) % 4)
        Base64.decode64(src)
      rescue StandardError
        nil
      end
    end
  end
end
