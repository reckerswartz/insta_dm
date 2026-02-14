class InstagramProfilePostComment < ApplicationRecord
  belongs_to :instagram_profile_post
  belongs_to :instagram_profile

  validates :body, presence: true

  scope :recent_first, -> { order(commented_at: :desc, id: :desc) }
end
