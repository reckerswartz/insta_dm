module Instagram
  class Client
    class ProfileStoryDatasetService
      def initialize(
        fetch_profile_details:,
        fetch_web_profile_info:,
        fetch_story_reel:,
        extract_story_item:,
        normalize_username:
      )
        @fetch_profile_details = fetch_profile_details
        @fetch_web_profile_info = fetch_web_profile_info
        @fetch_story_reel = fetch_story_reel
        @extract_story_item = extract_story_item
        @normalize_username = normalize_username
      end

      def call(username:, stories_limit: 20)
        normalized_username = normalize_username.call(username)
        raise "Username cannot be blank" if normalized_username.blank?

        details = fetch_profile_details.call(username: normalized_username)
        web_info = fetch_web_profile_info.call(normalized_username)
        user = web_info.is_a?(Hash) ? web_info.dig("data", "user") : nil
        user_id = user.is_a?(Hash) ? user["id"].to_s.strip : ""

        reel = user_id.present? ? fetch_story_reel.call(user_id: user_id, referer_username: normalized_username) : nil
        raw_items = reel.is_a?(Hash) ? Array(reel["items"]) : []

        stories = raw_items.first(stories_limit.to_i.clamp(1, 30)).filter_map do |item|
          extract_story_item.call(item, username: normalized_username, reel_owner_id: user_id)
        end

        {
          profile: details,
          user_id: user_id.presence,
          stories: stories,
          fetched_at: Time.current
        }
      end

      private

      attr_reader :fetch_profile_details, :fetch_web_profile_info, :fetch_story_reel, :extract_story_item, :normalize_username
    end
  end
end
