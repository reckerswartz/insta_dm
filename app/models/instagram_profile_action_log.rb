class InstagramProfileActionLog < ApplicationRecord
  ACTIONS = %w[
    fetch_profile_details
    verify_messageability
    analyze_profile
    analyze_profile_posts
    capture_profile_posts
    build_history
    sync_avatar
    sync_stories
    sync_stories_debug
    auto_story_reply
    post_comment
  ].freeze

  STATUSES = %w[queued running succeeded failed].freeze

  belongs_to :instagram_account
  belongs_to :instagram_profile

  encrypts :log_text

  after_commit :broadcast_account_audit_logs_refresh

  validates :action, presence: true, inclusion: { in: ACTIONS }
  validates :status, presence: true, inclusion: { in: STATUSES }
  validates :occurred_at, presence: true

  scope :recent_first, -> { order(occurred_at: :desc, id: :desc) }

  def mark_running!(extra_metadata: nil)
    update!(
      status: "running",
      started_at: started_at || Time.current,
      metadata: merge_metadata(extra_metadata),
      error_message: nil
    )
  end

  def mark_succeeded!(extra_metadata: nil, log_text: nil)
    update!(
      status: "succeeded",
      finished_at: Time.current,
      metadata: merge_metadata(extra_metadata),
      log_text: log_text.presence || self.log_text,
      error_message: nil
    )
  end

  def mark_failed!(error_message:, extra_metadata: nil)
    update!(
      status: "failed",
      finished_at: Time.current,
      metadata: merge_metadata(extra_metadata),
      error_message: error_message.to_s
    )
  end

  private

  def broadcast_account_audit_logs_refresh
    account = instagram_account
    return unless account

    RefreshAccountAuditLogsJob.enqueue_for(instagram_account_id: account.id, limit: 120)
  rescue StandardError
    nil
  end

  def merge_metadata(extra)
    base = metadata.is_a?(Hash) ? metadata : {}
    return base if extra.blank?

    base.merge(extra.to_h)
  end
end
