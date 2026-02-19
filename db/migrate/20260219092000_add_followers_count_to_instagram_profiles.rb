class AddFollowersCountToInstagramProfiles < ActiveRecord::Migration[8.1]
  def change
    add_column :instagram_profiles, :followers_count, :integer
    add_index :instagram_profiles, :followers_count
  end
end
