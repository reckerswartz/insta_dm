require "securerandom"

module Instagram
  class Client
    module FollowGraphFetchingService
    FOLLOW_GRAPH_CURSOR_CACHE_PREFIX = "instagram:follow_graph:cursor".freeze
    FOLLOW_GRAPH_CURSOR_TTL_HOURS = ENV.fetch("FOLLOW_GRAPH_CURSOR_TTL_HOURS", "72").to_i.clamp(1, 24 * 14)
    FOLLOW_GRAPH_MAX_PAGES_PER_RUN = ENV.fetch("FOLLOW_GRAPH_MAX_PAGES_PER_RUN", "4").to_i.clamp(1, 25)
    FOLLOW_GRAPH_API_PAGE_SIZE = 200
    FOLLOW_GRAPH_CYCLE_CACHE_PREFIX = "instagram:follow_graph:cycle".freeze
    FOLLOW_GRAPH_CYCLE_MAX_USERNAMES = ENV.fetch("FOLLOW_GRAPH_CYCLE_MAX_USERNAMES", "200000").to_i.clamp(5_000, 500_000)

    def sync_follow_graph!
      SyncFollowGraphService.new(
        account: @account,
        with_recoverable_session: method(:with_recoverable_session),
        with_authenticated_driver: method(:with_authenticated_driver),
        collect_conversation_users: method(:collect_conversation_users),
        collect_story_users: method(:collect_story_users),
        collect_follow_list: method(:collect_follow_list),
        upsert_follow_list: method(:upsert_follow_list!),
        follow_list_sync_context: method(:follow_list_sync_context)
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
      list_kind_sym = list_kind.to_sym
      start_cursor = follow_graph_cursor_for(list_kind: list_kind_sym, profile_username: profile_username)

      with_task_capture(driver: driver, task_name: "sync_collect_#{list_kind}", meta: meta) do
        raw = fetch_follow_list_via_api(
          profile_username: profile_username,
          list_kind: list_kind,
          driver: driver,
          starting_max_id: start_cursor,
          page_limit: FOLLOW_GRAPH_MAX_PAGES_PER_RUN
        )
        users = raw.is_a?(Hash) && raw[:users].is_a?(Hash) ? raw[:users] : (raw.is_a?(Hash) ? raw : {})
        next_max_id = raw.is_a?(Hash) ? raw[:next_max_id].to_s.strip.presence : nil
        complete = raw.is_a?(Hash) && raw.key?(:complete) ? ActiveModel::Type::Boolean.new.cast(raw[:complete]) : true
        fetch_failed = raw.is_a?(Hash) && ActiveModel::Type::Boolean.new.cast(raw[:fetch_failed])
        pages_fetched = raw.is_a?(Hash) ? raw[:pages_fetched].to_i : (users.any? ? 1 : 0)
        persist_follow_graph_cursor!(
          list_kind: list_kind_sym,
          profile_username: profile_username,
          next_max_id: next_max_id,
          complete: complete,
          fetch_failed: fetch_failed
        )

        context = {
          list_kind: list_kind_sym.to_s,
          profile_username: normalize_username(profile_username),
          starting_cursor: start_cursor,
          next_cursor: next_max_id,
          complete: complete,
          partial: !complete,
          pages_fetched: pages_fetched,
          fetch_failed: fetch_failed,
          fetched_usernames: users.length
        }
        remember_follow_list_sync_context!(list_kind: list_kind_sym, context: context)

        meta[:source] = "api_friendships"
        meta[:starting_cursor] = start_cursor
        meta[:next_cursor] = next_max_id
        meta[:complete] = complete
        meta[:partial] = !complete
        meta[:pages_fetched] = pages_fetched
        meta[:fetch_failed] = fetch_failed
        meta[:unique_usernames] = users.length
        users
      end
    end

    def follow_list_sync_context(list_kind = nil)
      contexts = @follow_list_sync_context.is_a?(Hash) ? @follow_list_sync_context : {}
      return contexts if list_kind.nil?

      contexts[list_kind.to_sym]
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

    def fetch_follow_list_via_api(profile_username:, list_kind:, driver: nil, starting_max_id: nil, page_limit: FOLLOW_GRAPH_MAX_PAGES_PER_RUN)
      uname = normalize_username(profile_username)
      return { users: {}, next_max_id: nil, complete: true, pages_fetched: 0, fetch_failed: false } if uname.blank?

      web_info = fetch_web_profile_info(uname, driver: driver)
      user = web_info.is_a?(Hash) ? web_info.dig("data", "user") : nil
      user_id = user.is_a?(Hash) ? user["id"].to_s.strip : ""
      return { users: {}, next_max_id: nil, complete: true, pages_fetched: 0, fetch_failed: false } if user_id.blank?

      endpoint = (list_kind.to_sym == :followers) ? "followers" : "following"
      max_id = starting_max_id.to_s.strip.presence
      users = {}
      pages = 0
      max_pages = page_limit.to_i.clamp(1, 50)

      loop do
        break if pages >= max_pages

        query = [ "count=#{FOLLOW_GRAPH_API_PAGE_SIZE}" ]
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
        pages += 1

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

      {
        users: users,
        next_max_id: max_id,
        complete: max_id.blank?,
        pages_fetched: pages,
        fetch_failed: false
      }
    rescue StandardError
      {
        users: {},
        next_max_id: starting_max_id.to_s.strip.presence,
        complete: false,
        pages_fetched: 0,
        fetch_failed: true
      }
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

    def remember_follow_list_sync_context!(list_kind:, context:)
      @follow_list_sync_context ||= {}
      @follow_list_sync_context[list_kind.to_sym] = context.is_a?(Hash) ? context.deep_dup : {}
    rescue StandardError
      nil
    end

    def persist_follow_graph_cursor!(list_kind:, profile_username:, next_max_id:, complete:, fetch_failed:)
      return if ActiveModel::Type::Boolean.new.cast(fetch_failed)

      key = follow_graph_cursor_cache_key(list_kind: list_kind, profile_username: profile_username)
      if ActiveModel::Type::Boolean.new.cast(complete) || next_max_id.to_s.blank?
        follow_graph_cache_store.delete(key)
      else
        follow_graph_cache_store.write(key, next_max_id.to_s, expires_in: FOLLOW_GRAPH_CURSOR_TTL_HOURS.hours)
      end
    rescue StandardError
      nil
    end

    def follow_graph_cursor_for(list_kind:, profile_username:)
      key = follow_graph_cursor_cache_key(list_kind: list_kind, profile_username: profile_username)
      follow_graph_cache_store.read(key).to_s.strip.presence
    rescue StandardError
      nil
    end

    def follow_graph_cursor_cache_key(list_kind:, profile_username:)
      uname = normalize_username(profile_username).presence || normalize_username(@account.username)
      kind = list_kind.to_s.presence || "unknown"
      "#{FOLLOW_GRAPH_CURSOR_CACHE_PREFIX}:account:#{@account.id}:#{uname.presence || 'unknown'}:#{kind}"
    end

    def follow_graph_cache_store
      return Rails.cache unless Rails.cache.is_a?(ActiveSupport::Cache::NullStore)

      @follow_graph_cache_store ||= ActiveSupport::Cache::MemoryStore.new(expires_in: FOLLOW_GRAPH_CURSOR_TTL_HOURS.hours)
    rescue StandardError
      Rails.cache
    end
    end
  end
end
