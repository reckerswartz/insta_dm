class DropRecipientsTable < ActiveRecord::Migration[8.1]
  def change
    drop_table :recipients do |t|
      t.boolean "can_message", default: false, null: false
      t.datetime "created_at", null: false
      t.string "display_name"
      t.bigint "instagram_account_id", null: false
      t.string "restriction_reason"
      t.boolean "selected", default: false, null: false
      t.string "source", default: "conversation", null: false
      t.boolean "story_visible", default: false, null: false
      t.datetime "updated_at", null: false
      t.string "username", null: false
      t.index ["instagram_account_id", "username"], name: "index_recipients_on_instagram_account_id_and_username", unique: true
      t.index ["instagram_account_id"], name: "index_recipients_on_instagram_account_id"
    end
  end
end
