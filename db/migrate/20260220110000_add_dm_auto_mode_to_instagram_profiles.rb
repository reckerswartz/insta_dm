class AddDmAutoModeToInstagramProfiles < ActiveRecord::Migration[8.0]
  def change
    add_column :instagram_profiles, :dm_auto_mode, :string, null: false, default: "draft_only"
    add_index :instagram_profiles, :dm_auto_mode
  end
end
