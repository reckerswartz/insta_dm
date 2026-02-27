class BackgroundJobLifecycle < ApplicationRecord
  STATUSES = %w[queued running completed failed discarded removed].freeze
  TERMINAL_STATUSES = %w[completed failed discarded removed].freeze

  belongs_to :instagram_account, optional: true
  belongs_to :instagram_profile, optional: true
  belongs_to :instagram_profile_post, optional: true

  validates :active_job_id, presence: true
  validates :job_class, presence: true
  validates :queue_name, presence: true
  validates :status, presence: true, inclusion: { in: STATUSES }
  validates :last_transition_at, presence: true

  scope :recent_first, -> { order(last_transition_at: :desc, id: :desc) }
  scope :story_related, -> { where("queue_name ILIKE '%story%' OR job_class ILIKE '%Story%'") }
  scope :active, -> { where.not(status: TERMINAL_STATUSES) }
  scope :terminal, -> { where(status: TERMINAL_STATUSES) }

  def terminal?
    TERMINAL_STATUSES.include?(status.to_s)
  end
end
