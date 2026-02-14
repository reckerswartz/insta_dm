class AddStoryInteractionStateToInstagramProfiles < ActiveRecord::Migration[8.0]
  def change
    change_table :instagram_profiles, bulk: true do |t|
      t.string :story_interaction_state
      t.string :story_interaction_reason
      t.datetime :story_interaction_checked_at
      t.datetime :story_interaction_retry_after_at
      t.boolean :story_reaction_available
    end

    add_index :instagram_profiles, :story_interaction_state
    add_index :instagram_profiles, :story_interaction_retry_after_at
  end
end
