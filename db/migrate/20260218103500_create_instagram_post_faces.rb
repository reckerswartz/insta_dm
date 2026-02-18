class CreateInstagramPostFaces < ActiveRecord::Migration[8.1]
  def change
    create_table :instagram_post_faces do |t|
      t.references :instagram_profile_post, null: false, foreign_key: true
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

    add_index :instagram_post_faces, [ :instagram_profile_post_id, :created_at ], name: "idx_post_faces_post_created"
    add_index :instagram_post_faces, :role
  end
end
