class AddMissingFkToConversationPeers < ActiveRecord::Migration[8.1]
  def change
    return unless table_exists?(:conversation_peers) && table_exists?(:instagram_accounts)

    if foreign_key_exists?(:conversation_peers, :instagram_accounts)
      return
    end

    add_foreign_key :conversation_peers, :instagram_accounts
  end
end
