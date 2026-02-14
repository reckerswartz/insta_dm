class CreateConversationPeers < ActiveRecord::Migration[8.1]
  def change
    create_table :conversation_peers do |t|
      t.string :username, null: false
      t.string :display_name
      t.datetime :last_message_at
      # NOTE:
      # This migration runs before CreateInstagramAccounts in timestamp order.
      # Avoid adding FK here so fresh PostgreSQL setups don't fail on missing table.
      t.references :instagram_account, null: false

      t.timestamps
    end

    add_index :conversation_peers, [ :instagram_account_id, :username ], unique: true
  end
end
