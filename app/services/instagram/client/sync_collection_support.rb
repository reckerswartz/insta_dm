module Instagram
  class Client
    module SyncCollectionSupport
      private

      def collect_conversation_users(driver)
        meta = { extraction: "inbox_page_source_verify_contact_row_exists" }

        with_task_capture(driver: driver, task_name: "sync_collect_conversation_users", meta: meta) do
          api_users = fetch_conversation_users_via_api(limit: 120)
          if api_users.present?
            meta[:source] = "api_direct_inbox"
            meta[:unique_usernames] = api_users.length
            return api_users
          end

          meta[:source] = "html_fallback"
          users = {}
          driver.navigate.to("#{INSTAGRAM_BASE_URL}/direct/inbox/")
          wait_for(driver, css: "body", timeout: 10)

          # Inbox content is often rendered via large JSON payloads; wait for those to exist.
          Selenium::WebDriver::Wait.new(timeout: 10).until do
            driver.page_source.to_s.include?("verifyContactRowExists") || driver.page_source.to_s.include?("LSVerifyContactRowExists")
          end

          verify_segments_total = 0
          extracted_total = 0

          8.times do
            html = driver.page_source.to_s
            extracted, verify_segments = extract_conversation_users_from_inbox_html(html)
            verify_segments_total += verify_segments
            extracted_total += extracted.length

            extracted.each do |username, attrs|
              users[username] ||= attrs
            end

            # Inbox uses a nested scroller in many builds; try to scroll that first.
            driver.execute_script(<<~JS)
              const candidate =
                document.querySelector("div[role='main']") ||
                document.querySelector("div[role='grid']") ||
                document.scrollingElement ||
                document.documentElement ||
                document.body;
              try { candidate.scrollTop = (candidate.scrollTop || 0) + 750; } catch (e) {}
              try { window.scrollBy(0, 750); } catch (e) {}
            JS
            sleep(0.4)
          end

          meta[:verify_contact_row_segments] = verify_segments_total
          meta[:extracted_usernames_total] = extracted_total
          meta[:unique_usernames] = users.length

          users
        end
      end

      def collect_story_users(driver)
        meta = { extraction: "home_stories_anchors_and_regex" }

        with_task_capture(driver: driver, task_name: "sync_collect_story_users", meta: meta) do
          api_users = fetch_story_users_via_api
          if api_users.present?
            meta[:source] = "api_reels_tray"
            meta[:unique_story_usernames] = api_users.length
            return api_users
          end

          meta[:source] = "html_fallback"
          users = {}
          driver.navigate.to(INSTAGRAM_BASE_URL)
          wait_for(driver, css: "body", timeout: 10)

          dismiss_common_overlays!(driver)

          html = driver.page_source.to_s
          extracted_users = extract_story_users_from_home_html(html)
          meta[:story_prefetch_usernames] = extracted_users.length

          extracted_users.each do |username|
            users[username] ||= { display_name: username }
          end

          # If we didn't get anything from prefetched query payloads, try DOM anchors as a fallback.
          if users.empty?
            begin
              Selenium::WebDriver::Wait.new(timeout: 12).until do
                driver.find_elements(css: "a[href*='/stories/']").any?
              end
            rescue Selenium::WebDriver::Error::TimeoutError
              meta[:story_anchor_wait_timed_out] = true
            end

            story_hrefs = driver.find_elements(css: "a[href*='/stories/']").map { |a| a.attribute("href").to_s }.reject(&:blank?)
            meta[:story_anchor_hrefs] = story_hrefs.length

            story_hrefs.each do |href|
              username = href.split("/stories/").last.to_s.split("/").first.to_s
              username = normalize_username(username)
              next if username.blank?

              users[username] ||= { display_name: username }
            end

            # Fallback: parse the page source for story links even if anchors use different tag/attrs.
            html = driver.page_source.to_s
            story_usernames = html.scan(%r{/stories/([A-Za-z0-9._]{1,30})/}).flatten.map { |u| normalize_username(u) }.reject(&:blank?).uniq
            meta[:story_regex_usernames] = story_usernames.length

            story_usernames.each do |username|
              users[username] ||= { display_name: username }
            end
          else
            meta[:story_anchor_hrefs] = 0
            meta[:story_regex_usernames] = 0
          end

          meta[:unique_story_usernames] = users.length

          users
        end
      end

      def fetch_conversation_users_via_api(limit: 120)
        users = {}
        cursor = nil
        remaining = limit.to_i.clamp(1, 400)
        safety = 0

        loop do
          safety += 1
          break if safety > 12
          break if remaining <= 0

          count = [ remaining, 50 ].min
          q = [ "limit=#{count}", "visual_message_return_type=unseen" ]
          q << "cursor=#{CGI.escape(cursor)}" if cursor.present?
          path = "/api/v1/direct_v2/inbox/?#{q.join('&')}"
          body = ig_api_get_json(path: path, referer: "#{INSTAGRAM_BASE_URL}/direct/inbox/")
          break unless body.is_a?(Hash)

          inbox = body["inbox"].is_a?(Hash) ? body["inbox"] : {}
          threads = Array(inbox["threads"])
          break if threads.empty?

          threads.each do |thread|
            next unless thread.is_a?(Hash)
            Array(thread["thread_users"]).each do |u|
              next unless u.is_a?(Hash)
              username = normalize_username(u["username"])
              next if username.blank?

              users[username] ||= {
                display_name: u["full_name"].to_s.strip.presence || username,
                profile_pic_url: CGI.unescapeHTML(u["profile_pic_url"].to_s).strip.presence
              }
            end
          end

          remaining -= threads.length
          cursor = inbox["oldest_cursor"].to_s.strip.presence
          break if cursor.blank?
        end

        users
      rescue StandardError
        {}
      end

      def fetch_story_users_via_api
        body = ig_api_get_json(path: "/api/v1/feed/reels_tray/", referer: INSTAGRAM_BASE_URL)
        return {} unless body.is_a?(Hash)

        tray_items =
          if body["tray"].is_a?(Array)
            body["tray"]
          elsif body["tray"].is_a?(Hash)
            Array(body.dig("tray", "items"))
          else
            []
          end

        users = {}
        tray_items.each do |item|
          next unless item.is_a?(Hash)
          user = item["user"].is_a?(Hash) ? item["user"] : item
          username = normalize_username(user["username"])
          next if username.blank?

          users[username] ||= {
            display_name: user["full_name"].to_s.strip.presence || username,
            profile_pic_url: CGI.unescapeHTML(user["profile_pic_url"].to_s).strip.presence
          }
        end

        users
      rescue StandardError
        {}
      end

      def source_for(username, conversation_users, story_users)
        in_conversation = conversation_users.key?(username)
        in_story = story_users.key?(username)

        return "conversation+story" if in_conversation && in_story
        return "story" if in_story

        "conversation"
      end
    end
  end
end
