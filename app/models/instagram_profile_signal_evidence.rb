class InstagramProfileSignalEvidence < ApplicationRecord
  belongs_to :instagram_account
  belongs_to :instagram_profile
  belongs_to :ai_analysis
  belongs_to :instagram_profile_insight

  validates :signal_type, presence: true

  scope :recent_first, -> { order(created_at: :desc, id: :desc) }
end
