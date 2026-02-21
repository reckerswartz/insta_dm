module Instagram
  class Client
    module StoryScraper
      module CarouselNavigation
        private
        def click_next_story_in_carousel!(driver:, current_ref:)
          previous_signature = visible_story_media_signature(driver)
          marker = find_story_next_button(driver)
          capture_task_html(
            driver: driver,
            task_name: "home_story_sync_next_button_probe",
            status: marker[:found] ? "ok" : "error",
            meta: {
              current_ref: current_ref,
              next_found: marker[:found],
              selector: marker[:selector],
              aria_label: marker[:aria_label],
              outer_html_preview: marker[:outer_html_preview]
            }
          )

          if marker[:found]
            begin
              el = driver.find_element(css: "[data-codex-story-next='1']")
              driver.action.move_to(el).click.perform
            rescue StandardError
              begin
                el = driver.find_element(css: "[data-codex-story-next='1']")
                js_click(driver, el)
              rescue StandardError
                driver.action.send_keys(:arrow_right).perform
              end
            ensure
              begin
                driver.execute_script("const el=document.querySelector('[data-codex-story-next=\"1\"]'); if (el) el.removeAttribute('data-codex-story-next');")
              rescue StandardError
                nil
              end
            end
          else
            driver.action.send_keys(:arrow_right).perform
          end

          sleep(1.0)
          gate_result = click_story_view_gate_if_present!(driver: driver)
          sleep(0.45) if gate_result[:clicked]
          new_ref = current_story_reference(driver.current_url.to_s)
          new_signature = visible_story_media_signature(driver)
          moved = (new_ref.present? && new_ref != current_ref) || (new_signature.present? && previous_signature.present? && new_signature != previous_signature)

          if !moved
            moved = recover_story_navigation_when_stalled!(
              driver: driver,
              current_ref: current_ref,
              previous_signature: previous_signature
            )
            if moved
              new_ref = current_story_reference(driver.current_url.to_s)
              new_signature = visible_story_media_signature(driver)
            end
          end

          capture_task_html(
            driver: driver,
            task_name: "home_story_sync_after_next_click",
            status: moved ? "ok" : "error",
            meta: {
              previous_ref: current_ref,
              new_ref: new_ref,
              view_gate_clicked: gate_result[:clicked],
              previous_signature: previous_signature.to_s.byteslice(0, 120),
              new_signature: new_signature.to_s.byteslice(0, 120),
              moved: moved
            }
          )
          moved
        rescue StandardError => e
          capture_task_html(
            driver: driver,
            task_name: "home_story_sync_next_click_error",
            status: "error",
            meta: { previous_ref: current_ref, error_class: e.class.name, error_message: e.message }
          )
          false
        end
        def find_story_next_button(driver)
          payload = driver.execute_script(<<~JS)
            const isVisible = (el) => {
              if (!el) return false;
              const s = window.getComputedStyle(el);
              if (!s || s.display === "none" || s.visibility === "hidden" || s.opacity === "0") return false;
              const r = el.getBoundingClientRect();
              return r.width > 6 && r.height > 6;
            };

            const candidates = [
              { sel: "button[aria-label='Next']", label: "button[aria-label='Next']" },
              { sel: "button[aria-label='Next story']", label: "button[aria-label='Next story']" },
              { sel: "[role='button'][aria-label='Next']", label: "[role='button'][aria-label='Next']" },
              { sel: "[role='button'][aria-label*='Next']", label: "[role='button'][aria-label*='Next']" },
              { sel: "svg[aria-label='Next']", label: "svg[aria-label='Next']" },
              { sel: "svg[aria-label*='Next']", label: "svg[aria-label*='Next']" }
            ];

            for (const c of candidates) {
              const nodes = Array.from(document.querySelectorAll(c.sel));
              const hit = nodes.find((n) => {
                const target = (n.tagName && n.tagName.toLowerCase() === "svg") ? (n.closest("button,[role='button']") || n) : n;
                return isVisible(target);
              });
              if (hit) {
                const target = (hit.tagName && hit.tagName.toLowerCase() === "svg") ? (hit.closest("button,[role='button']") || hit) : hit;
                try { target.setAttribute("data-codex-story-next", "1"); } catch (e) {}
                return {
                  found: true,
                  selector: c.label,
                  aria_label: target.getAttribute("aria-label") || "",
                  outer_html_preview: (target.outerHTML || "").slice(0, 800)
                };
              }
            }

            return { found: false, selector: "", aria_label: "", outer_html_preview: "" };
          JS

          return { found: false, selector: nil, aria_label: nil, outer_html_preview: nil } unless payload.is_a?(Hash)

          {
            found: payload["found"] == true,
            selector: payload["selector"].to_s.presence,
            aria_label: payload["aria_label"].to_s.presence,
            outer_html_preview: payload["outer_html_preview"].to_s.presence
          }
        rescue StandardError
          { found: false, selector: nil, aria_label: nil, outer_html_preview: nil }
        end

        def recover_story_navigation_when_stalled!(driver:, current_ref:, previous_signature:)
          excluded_username = normalize_username(current_ref.to_s.split(":").first.to_s)

          driver.navigate.to(INSTAGRAM_BASE_URL)
          wait_for(driver, css: "body", timeout: 12)
          dismiss_common_overlays!(driver)
          open_first_story_from_home_carousel!(
            driver: driver,
            excluded_usernames: excluded_username.present? ? [ excluded_username ] : []
          )
          click_story_view_gate_if_present!(driver: driver)

          recovered_ref = current_story_reference(driver.current_url.to_s)
          recovered_signature = visible_story_media_signature(driver)
          moved = (recovered_ref.present? && recovered_ref != current_ref) || (recovered_signature.present? && recovered_signature != previous_signature)

          capture_task_html(
            driver: driver,
            task_name: "home_story_sync_next_navigation_recovered",
            status: moved ? "ok" : "error",
            meta: {
              previous_ref: current_ref,
              recovered_ref: recovered_ref,
              excluded_username: excluded_username,
              previous_signature: previous_signature.to_s.byteslice(0, 120),
              recovered_signature: recovered_signature.to_s.byteslice(0, 120),
              moved: moved
            }
          )
          moved
        rescue StandardError => e
          capture_task_html(
            driver: driver,
            task_name: "home_story_sync_next_navigation_recovery_error",
            status: "error",
            meta: {
              previous_ref: current_ref,
              excluded_username: excluded_username,
              error_class: e.class.name,
              error_message: e.message.to_s.byteslice(0, 220)
            }
          )
          false
        end
      end
    end
  end
end
