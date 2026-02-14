class AddSessionStateToInstagramAccounts < ActiveRecord::Migration[8.1]
  def change
    add_column :instagram_accounts, :local_storage_json, :text
    add_column :instagram_accounts, :session_storage_json, :text
    add_column :instagram_accounts, :user_agent, :string
    add_column :instagram_accounts, :auth_snapshot_json, :text
  end
end
