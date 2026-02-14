class CreateInstagramProfileActionLogs < ActiveRecord::Migration[8.1]
  def change
    create_table :instagram_profile_action_logs do |t|
      t.references :instagram_account, null: false, foreign_key: true
      t.references :instagram_profile, null: false, foreign_key: true

      t.string :action, null: false
      t.string :status, null: false, default: "queued"
      t.string :trigger_source
      t.string :active_job_id
      t.string :queue_name

      t.datetime :occurred_at, null: false
      t.datetime :started_at
      t.datetime :finished_at

      t.json :metadata
      t.text :log_text
      t.text :error_message

      t.timestamps
    end

    add_index :instagram_profile_action_logs, [ :instagram_profile_id, :created_at ], name: "idx_profile_action_logs_profile_created"
    add_index :instagram_profile_action_logs, [ :instagram_account_id, :created_at ], name: "idx_profile_action_logs_account_created"
    add_index :instagram_profile_action_logs, :status
    add_index :instagram_profile_action_logs, [ :action, :status ]
    add_index :instagram_profile_action_logs, :active_job_id
  end
end
