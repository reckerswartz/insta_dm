class CreateAiApiCalls < ActiveRecord::Migration[8.1]
  def change
    create_table :ai_api_calls do |t|
      t.references :instagram_account, null: true, foreign_key: true
      t.string :provider, null: false
      t.string :operation, null: false
      t.string :category, null: false
      t.string :status, null: false
      t.integer :http_status
      t.integer :latency_ms
      t.integer :request_units
      t.integer :input_tokens
      t.integer :output_tokens
      t.integer :total_tokens
      t.text :error_message
      t.datetime :occurred_at, null: false
      t.json :metadata

      t.timestamps
    end

    add_index :ai_api_calls, :occurred_at
    add_index :ai_api_calls, [ :provider, :occurred_at ]
    add_index :ai_api_calls, [ :category, :occurred_at ]
    add_index :ai_api_calls, [ :operation, :occurred_at ]
    add_index :ai_api_calls, [ :status, :occurred_at ]
    add_index :ai_api_calls, [ :instagram_account_id, :occurred_at ]
  end
end
