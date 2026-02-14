class AddProfileAnalysisMediaAndDemographics < ActiveRecord::Migration[8.1]
  def change
    create_table :instagram_profile_posts do |t|
      t.references :instagram_account, null: false, foreign_key: true
      t.references :instagram_profile, null: false, foreign_key: true

      t.string :shortcode, null: false
      t.datetime :taken_at
      t.text :caption
      t.string :permalink
      t.string :source_media_url
      t.string :media_url_fingerprint
      t.integer :comments_count, null: false, default: 0
      t.datetime :last_synced_at
      t.json :metadata

      t.timestamps
    end

    add_index :instagram_profile_posts, [ :instagram_profile_id, :shortcode ], unique: true, name: "idx_profile_posts_profile_shortcode"
    add_index :instagram_profile_posts, [ :instagram_profile_id, :taken_at ]

    create_table :instagram_profile_post_comments do |t|
      t.references :instagram_profile_post, null: false, foreign_key: true
      t.references :instagram_profile, null: false, foreign_key: true

      t.string :author_username
      t.text :body, null: false
      t.datetime :commented_at
      t.json :metadata

      t.timestamps
    end

    add_index :instagram_profile_post_comments, [ :instagram_profile_post_id, :created_at ], name: "idx_profile_post_comments_post_created"

    change_table :instagram_profiles, bulk: true do |t|
      t.integer :ai_estimated_age
      t.float :ai_age_confidence
      t.string :ai_estimated_gender
      t.float :ai_gender_confidence
      t.string :ai_estimated_location
      t.float :ai_location_confidence
      t.text :ai_persona_summary
      t.datetime :ai_last_analyzed_at
    end
  end
end
