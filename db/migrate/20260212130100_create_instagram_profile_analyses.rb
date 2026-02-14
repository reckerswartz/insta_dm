class CreateInstagramProfileAnalyses < ActiveRecord::Migration[8.1]
  def change
    create_table :instagram_profile_analyses do |t|
      t.references :instagram_profile, null: false, foreign_key: true

      t.string :provider, null: false, default: "xai"
      t.string :model

      t.string :status, null: false, default: "queued"
      t.datetime :started_at
      t.datetime :finished_at
      t.text :error_message

      t.text :prompt
      t.text :response_text
      t.json :analysis
      t.json :metadata

      t.timestamps
    end

    add_index :instagram_profile_analyses, [ :instagram_profile_id, :created_at ]
    add_index :instagram_profile_analyses, :status
  end
end

