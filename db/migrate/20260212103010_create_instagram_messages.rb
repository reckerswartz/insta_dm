class CreateInstagramMessages < ActiveRecord::Migration[8.1]
  def change
    create_table :instagram_messages do |t|
      t.references :instagram_account, null: false, foreign_key: true
      t.references :instagram_profile, null: false, foreign_key: true

      t.string :direction, null: false, default: "outgoing"
      t.text :body, null: false
      t.string :status, null: false, default: "queued"
      t.text :error_message
      t.datetime :sent_at

      t.timestamps
    end

    add_index :instagram_messages, %i[instagram_account_id instagram_profile_id created_at],
              name: "index_instagram_messages_on_account_profile_created_at"
  end
end

