class AddBioAndIgUserIdToInstagramProfiles < ActiveRecord::Migration[8.1]
  def change
    add_column :instagram_profiles, :ig_user_id, :string
    add_column :instagram_profiles, :bio, :text

    add_index :instagram_profiles, :ig_user_id
  end
end

