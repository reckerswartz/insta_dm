class CreateBackgroundJobExecutionMetrics < ActiveRecord::Migration[8.1]
  def change
    create_table :background_job_execution_metrics do |t|
      t.string :active_job_id, null: false
      t.string :provider_job_id
      t.string :sidekiq_jid
      t.string :sidekiq_class
      t.string :job_class, null: false
      t.string :queue_name, null: false
      t.string :status, null: false
      t.integer :retry_count
      t.integer :queue_wait_ms
      t.integer :processing_duration_ms
      t.integer :total_time_ms
      t.bigint :transition_recorded_at_ms
      t.datetime :recorded_at, null: false
      t.bigint :instagram_account_id
      t.bigint :instagram_profile_id
      t.bigint :instagram_profile_post_id
      t.jsonb :metadata, null: false, default: {}
      t.timestamps
    end

    add_index :background_job_execution_metrics, :recorded_at
    add_index :background_job_execution_metrics, [:queue_name, :recorded_at]
    add_index :background_job_execution_metrics, [:job_class, :recorded_at]
    add_index :background_job_execution_metrics, [:status, :recorded_at]
    add_index :background_job_execution_metrics, :provider_job_id
    add_index :background_job_execution_metrics, :instagram_account_id
    add_index :background_job_execution_metrics, :instagram_profile_id
  end
end
