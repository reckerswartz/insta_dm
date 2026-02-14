class CreateSyncRuns < ActiveRecord::Migration[8.1]
  def change
    create_table :sync_runs do |t|
      t.references :instagram_account, null: false, foreign_key: true
      t.string :kind, null: false, default: "follow_graph"
      t.string :status, null: false, default: "queued" # queued|running|succeeded|failed
      t.datetime :started_at
      t.datetime :finished_at
      t.text :stats_json
      t.text :error_message

      t.timestamps
    end

    add_index :sync_runs, %i[instagram_account_id created_at]
    add_index :sync_runs, %i[instagram_account_id kind status]
  end
end

