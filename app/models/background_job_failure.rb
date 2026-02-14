class BackgroundJobFailure < ApplicationRecord
  validates :active_job_id, presence: true
  validates :job_class, presence: true
  validates :error_class, presence: true
  validates :error_message, presence: true
  validates :occurred_at, presence: true
end
