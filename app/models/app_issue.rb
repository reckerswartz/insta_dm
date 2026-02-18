class AppIssue < ApplicationRecord
  STATUSES = %w[open pending resolved].freeze
  SEVERITIES = %w[info warn error critical].freeze

  belongs_to :instagram_account, optional: true
  belongs_to :instagram_profile, optional: true
  belongs_to :background_job_failure, optional: true

  validates :fingerprint, presence: true, uniqueness: true
  validates :issue_type, :source, :title, presence: true
  validates :status, inclusion: { in: STATUSES }
  validates :severity, inclusion: { in: SEVERITIES }
  validates :first_seen_at, :last_seen_at, presence: true

  scope :recent_first, -> { order(last_seen_at: :desc, id: :desc) }
  scope :active, -> { where.not(status: "resolved") }

  after_commit :broadcast_live_updates

  def retryable?
    background_job_failure.present? && background_job_failure.retryable?
  end

  def mark_open!(notes: nil)
    update!(
      status: "open",
      resolved_at: nil,
      resolution_notes: notes.presence || resolution_notes
    )
  end

  def mark_pending!(notes: nil)
    update!(
      status: "pending",
      resolved_at: nil,
      resolution_notes: notes.presence || resolution_notes
    )
  end

  def mark_resolved!(notes: nil)
    update!(
      status: "resolved",
      resolved_at: Time.current,
      resolution_notes: notes.presence || resolution_notes
    )
  end

  private

  def broadcast_live_updates
    Ops::LiveUpdateBroadcaster.broadcast!(
      topic: "issues_changed",
      account_id: instagram_account_id,
      payload: { issue_id: id, status: status },
      throttle_key: "issues_changed"
    )
    Ops::LiveUpdateBroadcaster.broadcast!(
      topic: "dashboard_metrics_changed",
      account_id: instagram_account_id,
      payload: { source: "app_issue" },
      throttle_key: "dashboard_metrics_changed"
    )
  end
end
