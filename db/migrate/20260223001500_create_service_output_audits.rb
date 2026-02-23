class CreateServiceOutputAudits < ActiveRecord::Migration[8.0]
  def change
    create_table :service_output_audits do |t|
      t.string :service_name, null: false
      t.string :execution_source
      t.string :status, null: false, default: "completed"
      t.string :run_id
      t.string :active_job_id
      t.string :queue_name
      t.bigint :instagram_account_id
      t.bigint :instagram_profile_id
      t.bigint :instagram_profile_post_id
      t.bigint :instagram_profile_event_id
      t.integer :produced_count, null: false, default: 0
      t.integer :referenced_count, null: false, default: 0
      t.integer :persisted_count, null: false, default: 0
      t.integer :unused_count, null: false, default: 0
      t.jsonb :produced_paths, null: false, default: []
      t.jsonb :produced_leaf_keys, null: false, default: []
      t.jsonb :referenced_paths, null: false, default: []
      t.jsonb :persisted_paths, null: false, default: []
      t.jsonb :unused_leaf_keys, null: false, default: []
      t.jsonb :metadata, null: false, default: {}
      t.datetime :recorded_at, null: false
      t.timestamps
    end

    add_index :service_output_audits, :recorded_at
    add_index :service_output_audits, [ :service_name, :recorded_at ], name: "idx_service_output_audits_service_recorded"
    add_index :service_output_audits, [ :status, :recorded_at ], name: "idx_service_output_audits_status_recorded"
    add_index :service_output_audits, :active_job_id
    add_index :service_output_audits, :run_id
    add_index :service_output_audits, :instagram_account_id
    add_index :service_output_audits, :instagram_profile_id
    add_index :service_output_audits, :instagram_profile_post_id
    add_index :service_output_audits, :instagram_profile_event_id
  end
end
