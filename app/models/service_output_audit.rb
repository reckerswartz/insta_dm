class ServiceOutputAudit < ApplicationRecord
  validates :service_name, presence: true
  validates :status, presence: true
  validates :recorded_at, presence: true

  scope :recent_first, -> { order(recorded_at: :desc, id: :desc) }
  scope :within, ->(range) { where(recorded_at: range) }
  scope :completed, -> { where(status: "completed") }
  scope :failed, -> { where(status: "failed") }
end
