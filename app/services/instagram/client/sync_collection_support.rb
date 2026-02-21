module Instagram
  class Client
    module SyncCollectionSupport
      private

      def collect_conversation_users(driver)
        meta = { extraction: "api_direct_inbox" }

        with_task_capture(driver: driver, task_name: "sync_collect_conversation_users", meta: meta) do
          users = fetch_conversation_users_via_api(limit: 120, driver: driver)
          meta[:source] = "api_direct_inbox"
          meta[:unique_usernames] = users.length
          users
        end
      end

      def collect_story_users(driver)
        meta = { extraction: "api_reels_tray" }

        with_task_capture(driver: driver, task_name: "sync_collect_story_users", meta: meta) do
          users = fetch_story_users_via_api(driver: driver)
          meta[:source] = "api_reels_tray"
          meta[:unique_story_usernames] = users.length

          users
        end
      end

      def fetch_conversation_users_via_api(limit: 120, driver: nil)
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
          body = ig_api_get_json(
            path: path,
            referer: "#{INSTAGRAM_BASE_URL}/direct/inbox/",
            endpoint: "direct_v2/inbox",
            username: @account.username,
            driver: driver,
            retries: 2
          )
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

      def fetch_story_users_via_api(driver: nil)
        body = ig_api_get_json(
          path: "/api/v1/feed/reels_tray/",
          referer: INSTAGRAM_BASE_URL,
          endpoint: "feed/reels_tray",
          username: @account.username,
          driver: driver,
          retries: 2
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
