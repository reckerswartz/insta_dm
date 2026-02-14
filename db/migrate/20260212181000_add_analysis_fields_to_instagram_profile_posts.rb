class AddAnalysisFieldsToInstagramProfilePosts < ActiveRecord::Migration[8.1]
  def change
    change_table :instagram_profile_posts, bulk: true do |t|
      t.integer :likes_count, null: false, default: 0
      t.string :ai_status, null: false, default: "pending"
      t.string :ai_provider
      t.string :ai_model
      t.datetime :analyzed_at
      t.json :analysis
    end

    add_index :instagram_profile_posts, :ai_status
    add_index :instagram_profile_posts, [ :instagram_profile_id, :analyzed_at ], name: "idx_profile_posts_profile_analyzed"
  end
end
