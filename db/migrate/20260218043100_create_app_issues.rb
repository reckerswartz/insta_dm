class CreateAppIssues < ActiveRecord::Migration[8.1]
  def change
    create_table :app_issues do |t|
      t.string :fingerprint, null: false
      t.string :issue_type, null: false
      t.string :source, null: false
      t.string :severity, null: false, default: "error"
      t.string :status, null: false, default: "open"
      t.string :title, null: false
      t.text :details
      t.integer :occurrences, null: false, default: 1
      t.datetime :first_seen_at, null: false
      t.datetime :last_seen_at, null: false
      t.datetime :resolved_at
      t.text :resolution_notes
      t.bigint :instagram_account_id
      t.bigint :instagram_profile_id
      t.bigint :background_job_failure_id
      t.jsonb :metadata, null: false, default: {}
      t.timestamps
    end

    add_index :app_issues, :fingerprint, unique: true
    add_index :app_issues, %i[status last_seen_at], name: "idx_app_issues_status_last_seen"
    add_index :app_issues, %i[severity last_seen_at], name: "idx_app_issues_severity_last_seen"
    add_index :app_issues, :issue_type
    add_index :app_issues, :source
    add_index :app_issues, :instagram_account_id
    add_index :app_issues, :instagram_profile_id
    add_index :app_issues, :background_job_failure_id

    add_foreign_key :app_issues, :instagram_accounts
    add_foreign_key :app_issues, :instagram_profiles
    add_foreign_key :app_issues, :background_job_failures
  end
end
