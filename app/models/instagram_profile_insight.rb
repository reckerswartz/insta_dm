class InstagramProfileInsight < ApplicationRecord
  belongs_to :instagram_account
  belongs_to :instagram_profile
  belongs_to :ai_analysis

  has_one :instagram_profile_message_strategy, dependent: :destroy
  has_many :instagram_profile_signal_evidences, dependent: :destroy

  validates :last_refreshed_at, presence: true

  scope :recent_first, -> { order(created_at: :desc, id: :desc) }
end
