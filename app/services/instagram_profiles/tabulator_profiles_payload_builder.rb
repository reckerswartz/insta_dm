module InstagramProfiles
  class TabulatorProfilesPayloadBuilder
    def initialize(profiles:, total:, pages:, view_context:)
      @profiles = profiles
      @total = total
      @pages = pages
      @view_context = view_context
    end

    def call
      {
        data: profiles.map { |profile| serialize_profile(profile) },
        last_page: pages,
        last_row: total
      }
    end

    private

    attr_reader :profiles, :total, :pages, :view_context

    def serialize_profile(profile)
      {
        id: profile.id,
        username: profile.username,
        display_name: profile.display_name,
        following: profile.following,
        follows_you: profile.follows_you,
        mutual: profile.mutual?,
        can_message: profile.can_message,
        restriction_reason: profile.restriction_reason,
        last_synced_at: profile.last_synced_at&.iso8601,
        last_active_at: profile.last_active_at&.iso8601,
        avatar_url: avatar_url_for(profile)
      }
    end

    def avatar_url_for(profile)
      if profile.avatar.attached?
        Rails.application.routes.url_helpers.rails_blob_path(profile.avatar, only_path: true)
      elsif profile.profile_pic_url.present?
        profile.profile_pic_url
      else
        view_context.asset_path("default_avatar.svg")
      end
    end
  end
end
