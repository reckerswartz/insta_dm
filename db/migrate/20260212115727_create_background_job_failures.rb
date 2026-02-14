class CreateBackgroundJobFailures < ActiveRecord::Migration[8.1]
  def change
    create_table :background_job_failures do |t|
      t.string :active_job_id, null: false
      t.string :queue_name
      t.string :job_class, null: false
      t.text :arguments_json
      t.string :provider_job_id
      t.integer :solid_queue_job_id
      t.string :error_class, null: false
      t.text :error_message, null: false
      t.text :backtrace
      t.datetime :occurred_at, null: false
      t.json :metadata

      t.timestamps
    end

    add_index :background_job_failures, :occurred_at
    add_index :background_job_failures, :active_job_id
    add_index :background_job_failures, :job_class
  end
end
