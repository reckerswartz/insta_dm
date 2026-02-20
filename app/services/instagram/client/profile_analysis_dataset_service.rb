module Instagram
  class Client
    class ProfileAnalysisDatasetService
      def initialize(
        fetch_profile_details:,
        fetch_web_profile_info:,
        fetch_profile_feed_items_for_analysis:,
        extract_post_for_analysis:,
        enrich_missing_post_comments_via_browser:,
        normalize_username:
      )
        @fetch_profile_details = fetch_profile_details
        @fetch_web_profile_info = fetch_web_profile_info
        @fetch_profile_feed_items_for_analysis = fetch_profile_feed_items_for_analysis
        @extract_post_for_analysis = extract_post_for_analysis
        @enrich_missing_post_comments_via_browser = enrich_missing_post_comments_via_browser
        @normalize_username = normalize_username
      end

      def call(username:, posts_limit: nil, comments_limit: 8)
        normalized_username = normalize_username.call(username)
        raise "Username cannot be blank" if normalized_username.blank?

        details = fetch_profile_details.call(username: normalized_username)
        web_info = fetch_web_profile_info.call(normalized_username)
        user = web_info.is_a?(Hash) ? web_info.dig("data", "user") : nil
        user_id = user.is_a?(Hash) ? user["id"].to_s.strip.presence : nil
        user_id ||= details[:ig_user_id].to_s.strip.presence if details.is_a?(Hash)

        feed_result = fetch_profile_feed_items_for_analysis.call(
          username: normalized_username,
          user_id: user_id,
          posts_limit: posts_limit
        )
        items = Array(feed_result[:items])

        posts = items.filter_map do |item|
          extract_post_for_analysis.call(item, comments_limit: comments_limit, referer_username: normalized_username)
        end

        enrich_missing_post_comments_via_browser.call(
          username: normalized_username,
          posts: posts,
          comments_limit: comments_limit
        )

        {
          profile: details,
          posts: posts,
          fetched_at: Time.current,
          feed_fetch: feed_result.except(:items)
        }
      end

      private

      attr_reader :fetch_profile_details,
        :fetch_web_profile_info,
        :fetch_profile_feed_items_for_analysis,
        :extract_post_for_analysis,
        :enrich_missing_post_comments_via_browser,
        :normalize_username
    end
  end
end
