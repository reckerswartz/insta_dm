class AddActivityAndAvatarTrackingToInstagramProfiles < ActiveRecord::Migration[8.1]
  def change
    add_column :instagram_profiles, :last_story_seen_at, :datetime
    add_column :instagram_profiles, :last_post_at, :datetime
    add_column :instagram_profiles, :last_active_at, :datetime
    add_column :instagram_profiles, :avatar_url_fingerprint, :string
    add_column :instagram_profiles, :avatar_synced_at, :datetime
  end
end
