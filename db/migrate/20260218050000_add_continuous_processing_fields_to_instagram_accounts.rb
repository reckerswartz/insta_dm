class AddContinuousProcessingFieldsToInstagramAccounts < ActiveRecord::Migration[8.1]
  def change
    change_table :instagram_accounts, bulk: true do |t|
      t.boolean :continuous_processing_enabled, null: false, default: true
      t.string :continuous_processing_state, null: false, default: "idle"
      t.datetime :continuous_processing_last_started_at
      t.datetime :continuous_processing_last_finished_at
      t.datetime :continuous_processing_last_heartbeat_at
      t.text :continuous_processing_last_error
      t.integer :continuous_processing_failure_count, null: false, default: 0
      t.datetime :continuous_processing_retry_after_at
      t.datetime :continuous_processing_next_story_sync_at
      t.datetime :continuous_processing_next_feed_sync_at
      t.datetime :continuous_processing_next_profile_scan_at
    end

    add_index :instagram_accounts,
      [:continuous_processing_enabled, :continuous_processing_retry_after_at],
      name: "idx_accounts_processing_enabled_retry"

    add_index :instagram_accounts,
      [:continuous_processing_state, :continuous_processing_last_heartbeat_at],
      name: "idx_accounts_processing_state_heartbeat"
  end
end
