class AiApiCall < ApplicationRecord
  belongs_to :instagram_account, optional: true

  CATEGORIES = %w[image_analysis video_analysis report_generation text_generation healthcheck other].freeze
  STATUSES = %w[succeeded failed].freeze

  validates :provider, presence: true
  validates :operation, presence: true
  validates :category, presence: true, inclusion: { in: CATEGORIES }
  validates :status, presence: true, inclusion: { in: STATUSES }
  validates :occurred_at, presence: true

  scope :recent_first, -> { order(occurred_at: :desc, id: :desc) }
  scope :within, ->(range) { where(occurred_at: range) }
end
