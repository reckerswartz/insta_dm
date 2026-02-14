class CreateRecipients < ActiveRecord::Migration[8.1]
  def change
    create_table :recipients do |t|
      t.string :username, null: false
      t.string :display_name
      t.boolean :can_message, null: false, default: false
      t.string :restriction_reason
      t.string :source, null: false, default: "conversation"
      t.boolean :selected, null: false, default: false
      t.boolean :story_visible, null: false, default: false
      t.references :instagram_account, null: false, foreign_key: true

      t.timestamps
    end

    add_index :recipients, [ :instagram_account_id, :username ], unique: true
  end
end
