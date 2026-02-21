module Instagram
  class Client
    module FollowGraphFetchingService
    def sync_follow_graph!
      SyncFollowGraphService.new(
        account: @account,
        with_recoverable_session: method(:with_recoverable_session),
        with_authenticated_driver: method(:with_authenticated_driver),
        collect_conversation_users: method(:collect_conversation_users),
        collect_story_users: method(:collect_story_users),
        collect_follow_list: method(:collect_follow_list),
        upsert_follow_list: method(:upsert_follow_list!)
      ).call
    end

    def fetch_mutual_friends(profile_username:, limit: 36)
      max_results = limit.to_i.clamp(1, 100)
      fetch_mutual_friends_via_api(profile_username: profile_username, limit: max_results)
    rescue StandardError => e
      Rails.logger.warn("Instagram fetch_mutual_friends failed for #{profile_username}: #{e.class}: #{e.message}")
      []
    end

    def collect_follow_list(driver, list_kind:, profile_username:)
      meta = { list_kind: list_kind.to_s, profile_username: profile_username }

      with_task_capture(driver: driver, task_name: "sync_collect_#{list_kind}", meta: meta) do
        users = fetch_follow_list_via_api(profile_username: profile_username, list_kind: list_kind, driver: driver)
        meta[:source] = "api_friendships"
        meta[:unique_usernames] = users.length
        users
      end
    end

    def upsert_follow_list!(users_hash, following_flag:, follows_you_flag:)
      now = Time.current

      users_hash.each do |username, attrs|
        profile = @account.instagram_profiles.find_or_initialize_by(username: username)

        # If we already have a profile_pic_url, keep it unless we received a new one.
        new_pic = attrs.dig(:profile_pic_url).presence
        profile.profile_pic_url = new_pic if new_pic.present?

        new_display = attrs.dig(:display_name).presence
        profile.display_name = new_display if new_display.present?

        profile.following = true if following_flag
        profile.follows_you = true if follows_you_flag
        profile.last_synced_at = now
        profile.save!
      end
    end

    def fetch_follow_list_via_api(profile_username:, list_kind:, driver: nil)
      uname = normalize_username(profile_username)
      return {} if uname.blank?

      web_info = fetch_web_profile_info(uname, driver: driver)
      user = web_info.is_a?(Hash) ? web_info.dig("data", "user") : nil
      user_id = user.is_a?(Hash) ? user["id"].to_s.strip : ""
      return {} if user_id.blank?

      endpoint = (list_kind.to_sym == :followers) ? "followers" : "following"
      max_id = nil
      users = {}
      safety = 0

      loop do
        safety += 1
        break if safety > 25

        query = [ "count=200" ]
        query << "max_id=#{CGI.escape(max_id)}" if max_id.present?
        path = "/api/v1/friendships/#{user_id}/#{endpoint}/?#{query.join('&')}"
        body = ig_api_get_json(
          path: path,
          referer: "#{INSTAGRAM_BASE_URL}/#{uname}/",
          endpoint: "friendships/#{endpoint}",
          username: uname,
          driver: driver,
          retries: 2
        )
        break unless body.is_a?(Hash)

        Array(body["users"]).each do |entry|
          next unless entry.is_a?(Hash)
          username = normalize_username(entry["username"])
          next if username.blank?

          users[username] ||= {
            display_name: entry["full_name"].to_s.strip.presence || username,
            profile_pic_url: CGI.unescapeHTML(entry["profile_pic_url"].to_s).strip.presence
          }
        end

        max_id = body["next_max_id"].to_s.strip.presence
        break if max_id.blank?
      end

      users
    rescue StandardError
      {}
    end

    def fetch_mutual_friends_via_api(profile_username:, limit:)
      uname = normalize_username(profile_username)
      return [] if uname.blank?

      web_info = fetch_web_profile_info(uname)
      user = web_info.is_a?(Hash) ? web_info.dig("data", "user") : nil
      user_id = user.is_a?(Hash) ? user["id"].to_s.strip : ""
      return [] if user_id.blank?

      max_results = limit.to_i.clamp(1, 100)
      max_id = nil
      safety = 0
      mutuals = []
      seen_usernames = Set.new

      loop do
        break if mutuals.length >= max_results
        safety += 1
        break if safety > 25

        query = [ "count=#{[max_results, 200].min}" ]
        query << "max_id=#{CGI.escape(max_id)}" if max_id.present?

        # Use the dedicated mutual friends endpoint
        path = "/api/v1/friendships/#{user_id}/mutual_friends/?#{query.join('&')}"
        body = ig_api_get_json(
          path: path,
          referer: "#{INSTAGRAM_BASE_URL}/#{uname}/",
          endpoint: "friendships/mutual_friends",
          username: uname,
          retries: 2
        )
        break unless body.is_a?(Hash)

        users = Array(body["users"]).select { |entry| entry.is_a?(Hash) }
        break if users.empty?

        users.each do |entry|
          username = normalize_username(entry["username"])
          next if username.blank? || seen_usernames.include?(username)

          seen_usernames << username
          mutuals << {
            username: username,
            display_name: entry["full_name"].to_s.strip.presence || username,
            profile_pic_url: CGI.unescapeHTML(entry["profile_pic_url"].to_s).strip.presence
          }
          break if mutuals.length >= max_results
        end

        max_id = body["next_max_id"].to_s.strip.presence
        break if max_id.blank?
      end

      mutuals
    rescue StandardError
      []
    end
    end
  end
end
