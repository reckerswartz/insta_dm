class AddFailureKindAndRetryableToBackgroundJobFailures < ActiveRecord::Migration[8.1]
  def change
    add_column :background_job_failures, :failure_kind, :string, null: false, default: "runtime"
    add_column :background_job_failures, :retryable, :boolean, null: false, default: true

    add_index :background_job_failures, :failure_kind
    add_index :background_job_failures, %i[retryable occurred_at], name: "idx_background_job_failures_retryable_occurred"
  end
end
