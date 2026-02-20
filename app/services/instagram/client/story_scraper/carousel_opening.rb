module Instagram
  class Client
    module StoryScraper
      module CarouselOpening
        private
        def open_first_story_from_home_carousel!(driver:)
          started_at = Time.current
          deadline = started_at + 45.seconds  # Further increased timeout
          attempts = 0
          last_probe = {}
          prefetch_route_attempted = false
          excluded_usernames = []

          while Time.current < deadline
            attempts += 1
            dismiss_common_overlays!(driver)

            # Force scroll to ensure stories are loaded
            if attempts == 1
              begin
                driver.execute_script("window.scrollTo(0, 0);")
                sleep(1.0)
              rescue StandardError
                nil
              end
            end

            # Check if we're on the right page
            current_url = driver.current_url.to_s
            if !current_url.include?("instagram.com") && !current_url.include?(INSTAGRAM_BASE_URL)
              Rails.logger.warn "Not on Instagram page, redirecting. Current URL: #{current_url}" if defined?(Rails)
              begin
                driver.navigate.to(INSTAGRAM_BASE_URL)
                wait_for(driver, css: "body", timeout: 12)
                dismiss_common_overlays!(driver)
                sleep(2.0)
                next
              rescue StandardError => e
                Rails.logger.error "Failed to redirect to Instagram: #{e.message}" if defined?(Rails)
                next
              end
            end

            probe = detect_home_story_carousel_probe(driver, excluded_usernames: excluded_usernames)
            last_probe = probe

            # Enhanced debugging for failed story detection
            if attempts == 1 || (attempts % 3 == 0) || (probe[:target_count].to_i.zero? && probe[:anchor_count].to_i.zero? && probe[:prefetch_count].to_i.zero?)
              capture_task_html(
                driver: driver,
                task_name: "home_story_sync_debug_probe",
                status: "ok",
                meta: {
                  attempts: attempts,
                  target_count: probe[:target_count],
                  anchor_count: probe[:anchor_count],
                  prefetch_count: probe[:prefetch_count],
                  target_strategy: probe[:target_strategy],
                  debug_info: probe[:debug],
                  page_debug: probe[:page_debug],
                  current_url: current_url,
                  all_zero: probe[:target_count].to_i.zero? && probe[:anchor_count].to_i.zero? && probe[:prefetch_count].to_i.zero?
                }
              )
            end

            # Aggressive prefetch route attempt when no elements found
            if !prefetch_route_attempted && attempts >= 2 && (probe[:anchor_count].to_i.zero? || probe[:target_count].to_i.zero?) && Array(probe[:prefetch_usernames]).present?
              prefetch_route_attempted = true
              opened = open_story_from_prefetch_usernames(
                driver: driver,
                usernames: Array(probe[:prefetch_usernames]),
                attempts: attempts,
                probe: probe
              )
              return true if opened
            end

            # Try direct navigation if no stories found after multiple attempts
            if attempts >= 6 && probe[:target_count].to_i.zero? && probe[:anchor_count].to_i.zero? && probe[:prefetch_count].to_i.zero?
              # Try to navigate to stories directly as last resort
              begin
                Rails.logger.info "No stories found, attempting refresh and retry" if defined?(Rails)
                driver.navigate.to("#{INSTAGRAM_BASE_URL}/")
                wait_for(driver, css: "body", timeout: 12)
                dismiss_common_overlays!(driver)
                sleep(2.0)
                next
              rescue StandardError
                nil
              end
            end

            target = probe[:target]
            if target
              clicked_target = false
              begin
                driver.action.move_to(target).click.perform
                clicked_target = true
              rescue StandardError
                begin
                  js_click(driver, target)
                  clicked_target = true
                rescue StandardError
                  clicked_target = false
                end
              end

              if clicked_target
                sleep(0.8)
                dom = extract_story_dom_context(driver)
                unless story_viewer_ready?(dom)
                  current_url = driver.current_url.to_s
                  if current_url.include?("/live/")
                    live_username = extract_username_from_profile_like_path(current_url)
                    excluded_usernames << live_username if live_username.present? && !excluded_usernames.include?(live_username)
                  end

                  capture_task_html(
                    driver: driver,
                    task_name: "home_story_sync_first_story_opened",
                    status: "error",
                    meta: {
                      strategy: probe[:target_strategy],
                      attempts: attempts,
                      target_count: probe[:target_count],
                      anchor_count: probe[:anchor_count],
                      prefetch_story_usernames: probe[:prefetch_count],
                      reason: "clicked_target_but_story_frame_not_detected",
                      current_url: current_url,
                      excluded_usernames: excluded_usernames,
                      story_viewer_active: dom[:story_viewer_active],
                      story_frame_present: dom[:story_frame_present],
                      media_signature: dom[:media_signature].to_s.byteslice(0, 120),
                      debug_info: probe[:debug],
                      page_debug: probe[:page_debug]
                    }
                  )
                  begin
                    driver.navigate.to(INSTAGRAM_BASE_URL)
                    wait_for(driver, css: "body", timeout: 12)
                  rescue StandardError
                    nil
                  end
                  next
                end

                capture_task_html(
                  driver: driver,
                  task_name: "home_story_sync_first_story_opened",
                  status: "ok",
                  meta: {
                    strategy: probe[:target_strategy],
                    attempts: attempts,
                    target_count: probe[:target_count],
                    anchor_count: probe[:anchor_count],
                    prefetch_story_usernames: probe[:prefetch_count],
                    debug_info: probe[:debug],
                    page_debug: probe[:page_debug]
                  }
                )
                return true
              end
            end

            # Some IG builds rerender story nodes and invalidate Selenium element handles between probe and click.
            # When we have candidates but no stable handle, click directly in page JS as a fallback.
            if probe[:target_count].to_i.positive?
              js_fallback = click_home_story_open_target_via_js(driver, excluded_usernames: excluded_usernames)
              if js_fallback[:clicked]
                sleep(0.8)
                dom = extract_story_dom_context(driver)
                if story_viewer_ready?(dom)
                  capture_task_html(
                    driver: driver,
                    task_name: "home_story_sync_first_story_opened_js_fallback",
                    status: "ok",
                    meta: {
                      strategy: js_fallback[:strategy],
                        attempts: attempts,
                        target_count: js_fallback[:count],
                        anchor_count: probe[:anchor_count],
                        prefetch_story_usernames: probe[:prefetch_count],
                        excluded_usernames: excluded_usernames,
                        debug_info: probe[:debug],
                        page_debug: probe[:page_debug]
                      }
                    )
                    return true
                end
              end
            end

            # If no clickable tray anchors exist, open story route directly from prefetch usernames.
            if !prefetch_route_attempted && attempts >= 3 && Array(probe[:prefetch_usernames]).present?
              prefetch_route_attempted = true
              opened = open_story_from_prefetch_usernames(
                driver: driver,
                usernames: Array(probe[:prefetch_usernames]),
                attempts: attempts,
                probe: probe
              )
              return true if opened
            end

            sleep(1.0)
            # Story tray hydration can stall on initial render; one soft refresh helps recover.
            if attempts == 8 || attempts == 15
              begin
                driver.navigate.refresh
                wait_for(driver, css: "body", timeout: 12)
              rescue StandardError
                nil
              end
            end
          end

          capture_task_html(
            driver: driver,
            task_name: "home_story_sync_no_carousel_found",
            status: "error",
            meta: {
              attempts: attempts,
              elapsed_seconds: (Time.current - started_at).round(2),
              target_count: last_probe[:target_count],
              anchor_count: last_probe[:anchor_count],
              prefetch_story_usernames: last_probe[:prefetch_count],
              target_strategy: last_probe[:target_strategy],
              debug_info: last_probe[:debug],
              page_debug: last_probe[:page_debug],
              current_url: driver.current_url.to_s,
              page_title: begin
                driver.execute_script("return document.title;")
              rescue StandardError
                "unknown"
              end
            }
          )
          raise "No clickable active stories found in the home carousel after waiting #{(Time.current - started_at).round(1)}s (targets=#{last_probe[:target_count].to_i}, anchors=#{last_probe[:anchor_count].to_i}, prefetch=#{last_probe[:prefetch_count].to_i}, strategy=#{last_probe[:target_strategy]})"
        end
      end
    end
  end
end
