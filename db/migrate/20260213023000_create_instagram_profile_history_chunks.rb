class CreateInstagramProfileHistoryChunks < ActiveRecord::Migration[8.1]
  def change
    create_table :instagram_profile_history_chunks do |t|
      t.references :instagram_account, null: false, foreign_key: true
      t.references :instagram_profile, null: false, foreign_key: true
      t.integer :sequence, null: false
      t.text :content, null: false
      t.integer :word_count, null: false, default: 0
      t.integer :entry_count, null: false, default: 0
      t.datetime :starts_at
      t.datetime :ends_at
      t.json :metadata

      t.timestamps
    end

    add_index :instagram_profile_history_chunks, [ :instagram_profile_id, :sequence ], unique: true, name: "idx_profile_history_chunks_profile_sequence"
    add_index :instagram_profile_history_chunks, [ :instagram_profile_id, :created_at ], name: "idx_profile_history_chunks_profile_created"
  end
end
