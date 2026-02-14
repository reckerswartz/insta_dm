class CreateInstagramAccounts < ActiveRecord::Migration[8.1]
  def change
    create_table :instagram_accounts do |t|
      t.string :username, null: false
      t.text :cookies_json
      t.datetime :last_synced_at
      t.string :login_state, null: false, default: "not_authenticated"

      t.timestamps
    end

    add_index :instagram_accounts, :username, unique: true
  end
end
