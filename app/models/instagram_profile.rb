class InstagramProfile < ApplicationRecord
  DM_AUTO_MODES = %w[draft_only autonomous].freeze

  # Phase 11: engagement candidate filter thresholds. These are
  # deliberately lenient; adjust via ENV to fit the operator's taste.
  LIKELY_PAGE_FOLLOWER_THRESHOLD = ENV.fetch("LIKELY_PAGE_FOLLOWER_THRESHOLD", "10000").to_i

  # Tag names that flag a profile as a "page / irrelevant content source"
  # even when the is_business / is_verified signals aren't set. Mirrors
  # the list in Workspace::ActionsTodoQueueService#engagement_eligible?
  # so we have one canonical skip set.
  PAGE_PROFILE_TAGS = %w[page brand business company publisher].freeze

  # Tag names the operator uses to mark a profile as "friend-like",
  # meaning the story-reply / comment-generation pipeline should
  # prioritise it over neutral profiles. Derived from the existing
  # Instagram::ProfileScanPolicy::PERSONAL_OVERRIDE_TAGS list so one
  # set of tags drives both scan and engagement policies.
  FRIEND_PROFILE_TAGS = %w[friend female_friend male_friend personal_user relative].freeze

  # Explicit exclusion tag set by the operator (or the scan policy) to
  # mean "never engage with this profile", regardless of other signals.
  SKIP_PROFILE_TAGS = %w[profile_scan_excluded engagement_excluded].freeze

  belongs_to :instagram_account
  has_many :instagram_messages, dependent: :destroy
  has_many :instagram_profile_events, dependent: :destroy
  has_many :instagram_profile_analyses, dependent: :destroy
  has_many :instagram_profile_action_logs, dependent: :destroy
  has_many :instagram_profile_posts, dependent: :destroy
  has_many :instagram_posts, dependent: :destroy
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
  has_many :background_job_lifecycles, dependent: :nullify
  has_one :instagram_profile_behavior_profile, dependent: :destroy

  has_one_attached :avatar

  validates :username, presence: true
  validates :dm_auto_mode, inclusion: { in: DM_AUTO_MODES }, allow_blank: false
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

  def dm_draft_only?
    dm_auto_mode.to_s == "draft_only"
  end

  def dm_autonomous?
    dm_auto_mode.to_s == "autonomous"
  end

  def auto_reply_enabled?
    profile_tags.where(name: %w[automatic_reply automatic\ reply auto_reply auto\ reply]).exists?
  end

  # Phase 11 engagement-candidate predicates.
  # `likely_page?` returns true when the profile looks like a brand /
  # news / celebrity account -- one of the three signals configured in
  # Phase 11 (business, verified, follower count). Used by the story
  # auto-reply + feed-comment pipelines to avoid engaging with accounts
  # where a generated reply would be off-tone or spammy.
  def likely_page?
    is_business? || is_verified? || followers_count.to_i >= LIKELY_PAGE_FOLLOWER_THRESHOLD || page_tagged?
  end

  def friend_tagged?
    _engagement_tag_names.any? { |name| FRIEND_PROFILE_TAGS.include?(name) }
  end

  def skip_tagged?
    _engagement_tag_names.any? { |name| SKIP_PROFILE_TAGS.include?(name) }
  end

  def page_tagged?
    _engagement_tag_names.any? { |name| PAGE_PROFILE_TAGS.include?(name) }
  end

  # Combined eligibility for autonomous engagement (story reply / feed
  # comment). Returns a struct so callers can log the reason in addition
  # to the boolean. `friend_tagged?` never overrides a skip/page gate --
  # the operator's explicit skip tag wins over the friend tag.
  EngagementEligibility = Struct.new(:eligible, :reason, :priority, keyword_init: true) do
    def eligible?
      eligible
    end
  end

  def engagement_eligibility
    return EngagementEligibility.new(eligible: false, reason: "profile_skip_tagged", priority: -1) if skip_tagged?
    return EngagementEligibility.new(eligible: false, reason: "profile_likely_page", priority: -1) if likely_page?

    EngagementEligibility.new(eligible: true, reason: nil, priority: friend_tagged? ? 1 : 0)
  end

  def record_event!(kind:, external_id:, occurred_at: nil, metadata: {})
    eid = external_id.to_s.strip
    raise ArgumentError, "external_id is required for profile events" if eid.blank?

    attrs = { kind: kind.to_s, external_id: eid }
    event = instagram_profile_events.find_or_initialize_by(attrs)
    event.detected_at = Time.current
    event.occurred_at = occurred_at if occurred_at.present?
    event.metadata = (event.metadata || {}).merge(metadata.to_h)
    event.save!
    event
  rescue ActiveRecord::RecordNotUnique
    # Concurrent jobs can race on the unique (profile_id, kind, external_id) index.
    # Prefer returning the already-created row instead of bubbling a transient failure.
    existing_event = instagram_profile_events.find_by!(attrs)
    existing_event.update!(
      detected_at: Time.current,
      occurred_at: occurred_at.presence || existing_event.occurred_at,
      metadata: (existing_event.metadata || {}).merge(metadata.to_h)
    )
    existing_event
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

  def last_story_sync_completed_at
    background_job_lifecycles
      .story_related
      .where(status: "completed")
      .where.not(completed_at: nil)
      .maximum(:completed_at)
  end

  private

  def _engagement_tag_names
    @_engagement_tag_names ||=
      if association(:profile_tags).loaded?
        profile_tags.map { |tag| tag.name.to_s.strip.downcase }
      else
        profile_tags.pluck(:name).map { |value| value.to_s.strip.downcase }
      end
  rescue StandardError
    []
  end

  def broadcast_profiles_table_refresh
    Ops::LiveUpdateBroadcaster.broadcast!(
      topic: "profiles_table_changed",
      account_id: instagram_account_id,
      payload: { profile_id: id },
      throttle_key: "profiles_table_changed"
    )
  end
end
