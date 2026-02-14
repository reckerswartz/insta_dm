class AddAccountIdsToBackgroundJobFailures < ActiveRecord::Migration[8.1]
  def change
    add_column :background_job_failures, :instagram_account_id, :integer
    add_column :background_job_failures, :instagram_profile_id, :integer

    add_index :background_job_failures, :instagram_account_id
    add_index :background_job_failures, :instagram_profile_id
  end
end

