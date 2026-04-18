class BackgroundJobFailure < ApplicationRecord
  # `deprovisioned_class` captures payloads pointing at an Active Job class
  # that no longer exists (e.g. retry/dead/scheduled entries left over from a
  # deleted job class). `Ops::OrphanedJobClassMiddleware` emits these rows with
  # `retryable: false` so they can be excluded from the dashboard's live
  # counters. See `docs/audits/phase13/FINDINGS.md#F-admin-background-jobs-C1`.
  FAILURE_KINDS = %w[authentication transient runtime deprovisioned_class].freeze

  belongs_to :instagram_account, optional: true
  belongs_to :instagram_profile, optional: true
  has_many :app_issues, dependent: :nullify

  validates :active_job_id, presence: true, unless: :deprovisioned_class_failure?
  validates :job_class, presence: true
  validates :error_class, presence: true
  validates :error_message, presence: true
  validates :occurred_at, presence: true
  validates :failure_kind, inclusion: { in: FAILURE_KINDS }

  scope :recent_first, -> { order(occurred_at: :desc, id: :desc) }
  scope :excluding_deprovisioned, -> { where.not(failure_kind: "deprovisioned_class") }

  after_commit :broadcast_live_updates

  def auth_failure?
    failure_kind == "authentication"
  end

  def deprovisioned_class_failure?
    failure_kind == "deprovisioned_class"
  end

  def retryable_now?
    retryable? && !auth_failure? && !deprovisioned_class_failure?
  end

  def retryable?
    self[:retryable] == true
  end

  private

  def broadcast_live_updates
    Ops::LiveUpdateBroadcaster.broadcast!(
      topic: "job_failures_changed",
      account_id: instagram_account_id,
      payload: { failure_id: id, failure_kind: failure_kind },
      throttle_key: "job_failures_changed"
    )
    Ops::LiveUpdateBroadcaster.broadcast!(
      topic: "jobs_changed",
      account_id: instagram_account_id,
      payload: { source: "background_job_failure", failure_id: id },
      throttle_key: "jobs_changed"
    )
  end
end
