class Recipient < ApplicationRecord
  belongs_to :instagram_account

  validates :username, presence: true

  scope :eligible, -> { where(can_message: true) }
  scope :selected, -> { where(selected: true) }
end
