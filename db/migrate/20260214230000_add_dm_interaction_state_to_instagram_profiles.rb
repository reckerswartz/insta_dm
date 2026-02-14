class AddDmInteractionStateToInstagramProfiles < ActiveRecord::Migration[8.1]
  def change
    change_table :instagram_profiles, bulk: true do |t|
      t.string :dm_interaction_state
      t.string :dm_interaction_reason
      t.datetime :dm_interaction_checked_at
      t.datetime :dm_interaction_retry_after_at
    end

    add_index :instagram_profiles, :dm_interaction_state
    add_index :instagram_profiles, :dm_interaction_retry_after_at
  end
end
