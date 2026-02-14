class ConversationPeer < ApplicationRecord
  belongs_to :instagram_account

  validates :username, presence: true
end
