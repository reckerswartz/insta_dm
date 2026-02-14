class InstagramProfileEvent < ApplicationRecord
  belongs_to :instagram_profile

  has_one_attached :media
  has_many :instagram_stories, foreign_key: :source_event_id, dependent: :nullify

  validates :kind, presence: true
  validates :external_id, presence: true
  validates :detected_at, presence: true

  after_commit :broadcast_account_audit_logs_refresh
  after_commit :broadcast_story_archive_refresh, on: %i[create update]
  after_commit :append_profile_history_narrative, on: :create

  STORY_ARCHIVE_EVENT_KINDS = %w[
    story_downloaded
    story_image_downloaded_via_feed
    story_media_downloaded_via_feed
  ].freeze

  def self.broadcast_story_archive_refresh!(account:)
    return unless account

    Turbo::StreamsChannel.broadcast_replace_to(
      [account, :story_archive],
      target: "story_media_archive_refresh_signal",
      partial: "instagram_accounts/story_archive_refresh_signal",
      locals: { refreshed_at: Time.current }
    )
  rescue StandardError
    nil
  end

  private

  def broadcast_account_audit_logs_refresh
    account = instagram_profile&.instagram_account
    return unless account

    entries = Ops::AuditLogBuilder.for_account(instagram_account: account, limit: 120)
    Turbo::StreamsChannel.broadcast_replace_to(
      account,
      target: "account_audit_logs_section",
      partial: "instagram_accounts/audit_logs_section",
      locals: { recent_audit_entries: entries }
    )
  rescue StandardError
    nil
  end

  def append_profile_history_narrative
    Ai::ProfileHistoryNarrativeBuilder.append_event!(self)
  rescue StandardError
    nil
  end

  def broadcast_story_archive_refresh
    return unless STORY_ARCHIVE_EVENT_KINDS.include?(kind.to_s)

    account = instagram_profile&.instagram_account
    self.class.broadcast_story_archive_refresh!(account: account)
  rescue StandardError
    nil
  end
end
