class InstagramProfileAnalysis < ApplicationRecord
  belongs_to :instagram_profile

  # These contain potentially sensitive derived notes; keep them encrypted at rest.
  encrypts :prompt
  encrypts :response_text

  validates :provider, presence: true
  validates :status, presence: true

  scope :recent_first, -> { order(created_at: :desc, id: :desc) }
end

