class InstagramPostInsight < ApplicationRecord
  belongs_to :instagram_account
  belongs_to :instagram_post
  belongs_to :ai_analysis

  has_many :instagram_post_entities, dependent: :destroy

  scope :recent_first, -> { order(created_at: :desc, id: :desc) }
end
