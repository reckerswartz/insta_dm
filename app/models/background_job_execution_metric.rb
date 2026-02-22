class BackgroundJobExecutionMetric < ApplicationRecord
  STATUSES = %w[completed failed].freeze

  belongs_to :instagram_account, optional: true
  belongs_to :instagram_profile, optional: true

  validates :active_job_id, presence: true
  validates :job_class, presence: true
  validates :queue_name, presence: true
  validates :status, presence: true, inclusion: { in: STATUSES }
  validates :recorded_at, presence: true

  scope :recent_first, -> { order(recorded_at: :desc, id: :desc) }
  scope :within, ->(range) { where(recorded_at: range) }
  scope :completed, -> { where(status: "completed") }
  scope :failed, -> { where(status: "failed") }
end
