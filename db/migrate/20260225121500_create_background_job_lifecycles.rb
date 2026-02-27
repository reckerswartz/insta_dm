class CreateBackgroundJobLifecycles < ActiveRecord::Migration[8.0]
  def change
    create_table :background_job_lifecycles do |t|
      t.string :active_job_id, null: false
      t.string :provider_job_id
      t.string :sidekiq_jid
      t.string :sidekiq_class
      t.string :job_class, null: false
      t.string :queue_name, null: false
      t.string :status, null: false
      t.bigint :instagram_account_id
      t.bigint :instagram_profile_id
      t.bigint :instagram_profile_post_id
      t.string :related_model_type
      t.bigint :related_model_id
      t.string :story_id
      t.datetime :queued_at
      t.datetime :started_at
      t.datetime :completed_at
      t.datetime :failed_at
      t.datetime :discarded_at
      t.datetime :removed_at
      t.datetime :last_transition_at, null: false
      t.string :error_class
      t.text :error_message
      t.jsonb :metadata, null: false, default: {}
      t.timestamps
    end

    add_index :background_job_lifecycles, :active_job_id, unique: true
    add_index :background_job_lifecycles, :provider_job_id
    add_index :background_job_lifecycles, [ :status, :last_transition_at ], name: "idx_job_lifecycles_status_transition"
    add_index :background_job_lifecycles, [ :queue_name, :status, :last_transition_at ], name: "idx_job_lifecycles_queue_status_transition"
    add_index :background_job_lifecycles, [ :job_class, :last_transition_at ], name: "idx_job_lifecycles_class_transition"
    add_index :background_job_lifecycles, [ :instagram_account_id, :last_transition_at ], name: "idx_job_lifecycles_account_transition"
    add_index :background_job_lifecycles, [ :instagram_profile_id, :last_transition_at ], name: "idx_job_lifecycles_profile_transition"
    add_index :background_job_lifecycles, [ :related_model_type, :related_model_id ], name: "idx_job_lifecycles_related_model"

    add_foreign_key :background_job_lifecycles, :instagram_accounts
    add_foreign_key :background_job_lifecycles, :instagram_profiles
    add_foreign_key :background_job_lifecycles, :instagram_profile_posts
  end
end
