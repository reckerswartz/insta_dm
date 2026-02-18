class InstagramProfile < ApplicationRecord
  belongs_to :instagram_account
  has_many :instagram_messages, dependent: :destroy
  has_many :instagram_profile_events, dependent: :destroy
  has_many :instagram_profile_analyses, dependent: :destroy
  has_many :instagram_profile_action_logs, dependent: :destroy
  has_many :instagram_profile_posts, dependent: :destroy
  has_many :instagram_post_faces, through: :instagram_profile_posts
  has_many :instagram_profile_post_comments, dependent: :destroy
  has_many :instagram_profile_insights, dependent: :destroy
  has_many :instagram_profile_message_strategies, dependent: :destroy
  has_many :instagram_profile_signal_evidences, dependent: :destroy
  has_many :instagram_profile_history_chunks, dependent: :destroy
  has_many :instagram_stories, dependent: :destroy
  has_many :instagram_story_people, dependent: :destroy
  has_many :ai_analyses, as: :analyzable, dependent: :destroy
  has_many :instagram_profile_taggings, dependent: :destroy
  has_many :profile_tags, through: :instagram_profile_taggings
  has_many :app_issues, dependent: :nullify
  has_many :active_storage_ingestions, dependent: :nullify
  has_one :instagram_profile_behavior_profile, dependent: :destroy

  has_one_attached :avatar

  validates :username, presence: true
  after_commit :broadcast_profiles_table_refresh

  def mutual?
    following && follows_you
  end

  def display_label
    display_name.presence || username
  end

  def recompute_last_active!
    self.last_active_at = [ last_story_seen_at, last_post_at ].compact.max
  end

  def story_reply_allowed?
    story_interaction_state.to_s == "reply_available"
  end

  def story_reply_retry_pending?
    story_interaction_state.to_s == "unavailable" &&
      story_interaction_retry_after_at.present? &&
      story_interaction_retry_after_at > Time.current
  end

  def dm_allowed?
    dm_interaction_state.to_s == "messageable" || can_message == true
  end

  def dm_retry_pending?
    dm_interaction_state.to_s == "unavailable" &&
      dm_interaction_retry_after_at.present? &&
      dm_interaction_retry_after_at > Time.current
  end

  def record_event!(kind:, external_id:, occurred_at: nil, metadata: {})
    eid = external_id.to_s.strip
    raise ArgumentError, "external_id is required for profile events" if eid.blank?

    event = instagram_profile_events.find_or_initialize_by(kind: kind.to_s, external_id: eid)
    event.detected_at = Time.current
    event.occurred_at = occurred_at if occurred_at.present?
    event.metadata = (event.metadata || {}).merge(metadata.to_h)
    event.save!
    event
  end

  def latest_analysis
    ai_analyses.where(purpose: "profile").recent_first.first ||
      instagram_profile_analyses.recent_first.first
  end

  def history_narrative_text(max_chunks: 3)
    chunks = instagram_profile_history_chunks.recent_first.limit(max_chunks.to_i.clamp(1, 12)).to_a.reverse
    chunks.map { |chunk| chunk.content.to_s.strip }.reject(&:blank?).join("\n")
  end

  def history_narrative_chunks(max_chunks: 6)
    instagram_profile_history_chunks.recent_first.limit(max_chunks.to_i.clamp(1, 24)).map do |chunk|
      {
        sequence: chunk.sequence,
        starts_at: chunk.starts_at&.iso8601,
        ends_at: chunk.ends_at&.iso8601,
        word_count: chunk.word_count,
        entry_count: chunk.entry_count,
        content: chunk.content.to_s
      }
    end
  end

  private

  def broadcast_profiles_table_refresh
    Ops::LiveUpdateBroadcaster.broadcast!(
      topic: "profiles_table_changed",
      account_id: instagram_account_id,
      payload: { profile_id: id },
      throttle_key: "profiles_table_changed"
    )
  end
end
