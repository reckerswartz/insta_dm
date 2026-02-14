class InstagramPostEntity < ApplicationRecord
  belongs_to :instagram_account
  belongs_to :instagram_post
  belongs_to :instagram_post_insight

  validates :entity_type, presence: true
  validates :value, presence: true

  scope :recent_first, -> { order(created_at: :desc, id: :desc) }
end
