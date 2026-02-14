class CreateAiProviderSettingsAndAiAnalyses < ActiveRecord::Migration[8.1]
  def change
    create_table :ai_provider_settings do |t|
      t.string :provider, null: false
      t.boolean :enabled, null: false, default: false
      t.integer :priority, null: false, default: 100
      t.text :api_key
      t.json :config

      t.timestamps
    end

    add_index :ai_provider_settings, :provider, unique: true
    add_index :ai_provider_settings, [ :enabled, :priority ]

    create_table :ai_analyses do |t|
      t.integer :instagram_account_id, null: false
      t.references :analyzable, polymorphic: true, null: false
      t.string :purpose, null: false # profile|post
      t.string :provider, null: false
      t.string :model
      t.string :status, null: false, default: "queued" # queued|running|succeeded|failed
      t.datetime :started_at
      t.datetime :finished_at
      t.text :prompt
      t.text :response_text
      t.json :analysis
      t.json :metadata
      t.text :error_message

      t.timestamps
    end

    add_index :ai_analyses, :instagram_account_id
    add_index :ai_analyses, [ :instagram_account_id, :created_at ]
    add_index :ai_analyses, [ :analyzable_type, :analyzable_id, :created_at ], name: "idx_ai_analyses_on_analyzable_created"
    add_index :ai_analyses, [ :provider, :purpose, :status ]

    add_foreign_key :ai_analyses, :instagram_accounts
  end
end
