class CreateStoryIntelligencePipelineTables < ActiveRecord::Migration[8.1]
  def change
    create_table :instagram_stories do |t|
      t.references :instagram_account, null: false, foreign_key: true
      t.references :instagram_profile, null: false, foreign_key: true
      t.references :source_event, foreign_key: { to_table: :instagram_profile_events }
      t.string :story_id, null: false
      t.string :media_type
      t.string :media_url
      t.string :image_url
      t.string :video_url
      t.datetime :taken_at
      t.datetime :expires_at
      t.boolean :processed, null: false, default: false
      t.string :processing_status, null: false, default: "pending"
      t.datetime :processed_at
      t.json :metadata

      t.timestamps
    end
    add_index :instagram_stories, [ :instagram_profile_id, :story_id ], unique: true
    add_index :instagram_stories, [ :instagram_account_id, :processed ]
    add_index :instagram_stories, :processing_status

    create_table :instagram_story_people do |t|
      t.references :instagram_account, null: false, foreign_key: true
      t.references :instagram_profile, null: false, foreign_key: true
      t.string :role, null: false, default: "secondary_person"
      t.string :label
      t.datetime :first_seen_at
      t.datetime :last_seen_at
      t.integer :appearance_count, null: false, default: 0
      t.json :canonical_embedding
      t.json :metadata

      t.timestamps
    end
    add_index :instagram_story_people, :role
    add_index :instagram_story_people, [ :instagram_profile_id, :last_seen_at ]

    create_table :instagram_story_faces do |t|
      t.references :instagram_story, null: false, foreign_key: true
      t.references :instagram_story_person, foreign_key: true
      t.string :role, null: false, default: "unknown"
      t.float :detector_confidence
      t.float :match_similarity
      t.string :embedding_version
      t.json :embedding
      t.json :bounding_box
      t.json :metadata

      t.timestamps
    end
    add_index :instagram_story_faces, [ :instagram_story_id, :created_at ]
    add_index :instagram_story_faces, :role

    create_table :instagram_profile_behavior_profiles do |t|
      t.references :instagram_profile, null: false, foreign_key: true, index: { unique: true }
      t.float :activity_score
      t.json :behavioral_summary
      t.json :metadata

      t.timestamps
    end
  end
end
