class AiAnalysis < ApplicationRecord
  belongs_to :instagram_account
  belongs_to :analyzable, polymorphic: true
  belongs_to :cached_from_analysis, class_name: "AiAnalysis", foreign_key: :cached_from_ai_analysis_id, optional: true
  has_many :cached_copies, class_name: "AiAnalysis", foreign_key: :cached_from_ai_analysis_id, dependent: :nullify
  has_one :instagram_profile_insight, dependent: :destroy
  has_one :instagram_profile_message_strategy, dependent: :destroy
  has_many :instagram_profile_signal_evidences, dependent: :destroy
  has_one :instagram_post_insight, dependent: :destroy

  encrypts :prompt
  encrypts :response_text

  validates :purpose, presence: true, inclusion: { in: %w[profile post] }
  validates :provider, presence: true
  validates :status, presence: true

  scope :recent_first, -> { order(created_at: :desc, id: :desc) }
  scope :succeeded, -> { where(status: "succeeded") }
  scope :reusable_for, ->(purpose:, media_fingerprint:) {
    succeeded
      .where(purpose: purpose, media_fingerprint: media_fingerprint)
      .where.not(analysis: nil)
      .recent_first
  }
end
