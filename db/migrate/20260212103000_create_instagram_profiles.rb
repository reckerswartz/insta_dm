class CreateInstagramProfiles < ActiveRecord::Migration[8.1]
  def change
    create_table :instagram_profiles do |t|
      t.references :instagram_account, null: false, foreign_key: true
      t.string :username, null: false
      t.string :display_name
      t.text :profile_pic_url

      t.boolean :following, null: false, default: false
      t.boolean :follows_you, null: false, default: false

      # Messaging eligibility is expensive/flaky to compute at scale; we persist the latest known state.
      t.boolean :can_message
      t.string :restriction_reason

      t.datetime :last_synced_at

      t.timestamps
    end

    add_index :instagram_profiles, %i[instagram_account_id username], unique: true
    add_index :instagram_profiles, %i[instagram_account_id following follows_you]
  end
end

