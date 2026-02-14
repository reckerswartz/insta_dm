class CreateInstagramProfileEvents < ActiveRecord::Migration[8.1]
  def change
    create_table :instagram_profile_events do |t|
      t.references :instagram_profile, null: false, foreign_key: true
      t.string :kind, null: false
      t.string :external_id
      t.datetime :occurred_at
      t.datetime :detected_at, null: false
      t.json :metadata

      t.timestamps
    end

    add_index :instagram_profile_events, %i[instagram_profile_id detected_at]
    add_index :instagram_profile_events, %i[instagram_profile_id kind external_id], unique: true
  end
end
