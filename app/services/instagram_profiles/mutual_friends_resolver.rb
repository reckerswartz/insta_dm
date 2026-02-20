module InstagramProfiles
  class MutualFriendsResolver
    def initialize(account:, profile:, client: Instagram::Client.new(account: account))
      @account = account
      @profile = profile
      @client = client
    end

    def call(limit: 36)
      rows = client.fetch_mutual_friends(profile_username: profile.username, limit: limit)
      usernames = rows.filter_map { |entry| normalize_username(entry[:username] || entry["username"]) }
      existing_profiles = account.instagram_profiles.where(username: usernames).with_attached_avatar.index_by(&:username)

      rows.filter_map do |entry|
        username = normalize_username(entry[:username] || entry["username"])
        next if username.blank? || username == normalize_username(profile.username)

        display_name = entry[:display_name] || entry["display_name"]
        profile_pic_url = entry[:profile_pic_url] || entry["profile_pic_url"]

        existing = existing_profiles[username]
        if existing
          existing.display_name = display_name if existing.display_name.blank? && display_name.present?
          existing.profile_pic_url = profile_pic_url if existing.profile_pic_url.blank? && profile_pic_url.present?
          existing
        else
          account.instagram_profiles.new(
            username: username,
            display_name: display_name.presence,
            profile_pic_url: profile_pic_url.presence
          )
        end
      end
    rescue StandardError => e
      Rails.logger.warn("Failed to resolve mutual friends for profile #{profile&.username}: #{e.class}: #{e.message}")
      []
    end

    private

    attr_reader :account, :profile, :client

    def normalize_username(value)
      value.to_s.strip.downcase
    end
  end
end
