class InstagramStoryPerson < ApplicationRecord
  ROLES = %w[primary_user secondary_person unknown].freeze
  INACTIVE_MATCHING_STATUSES = %w[incorrect irrelevant synthetic].freeze

  belongs_to :instagram_account
  belongs_to :instagram_profile

  has_many :instagram_story_faces, dependent: :nullify
  has_many :instagram_post_faces, dependent: :nullify

  validates :role, presence: true, inclusion: { in: ROLES }

  scope :recently_seen, -> { order(last_seen_at: :desc, id: :desc) }

  def display_label
    label.to_s.presence || "person_#{id}"
  end

  def metadata_hash
    metadata.is_a?(Hash) ? metadata : {}
  end

  def feedback_metadata
    value = metadata_hash["user_feedback"]
    value.is_a?(Hash) ? value : {}
  end

  def real_person_status
    feedback_metadata["real_person_status"].to_s.presence || "unverified"
  end

  def merged_into_person_id
    value = metadata_hash["merged_into_person_id"]
    value.present? ? value.to_i : nil
  end

  def merged?
    merged_into_person_id.present?
  end

  def active_for_matching?
    return false if merged?

    !INACTIVE_MATCHING_STATUSES.include?(real_person_status)
  end

  def identity_confidence
    raw = metadata_hash["identity_confidence"]
    return 0.0 if raw.nil?

    raw.to_f.clamp(0.0, 1.0)
  end

  def sync_identity_confidence!(timestamp: Time.current)
    meta = metadata_hash.deep_dup
    meta["identity_confidence"] = self.class.identity_confidence_score(
      appearance_count: appearance_count.to_i,
      role: role.to_s,
      metadata: meta
    )
    update_columns(metadata: meta, updated_at: timestamp)
    meta["identity_confidence"].to_f
  end

  def self.identity_confidence_score(appearance_count:, role:, metadata:)
    count = appearance_count.to_i
    score = [ count / 10.0, 1.0 ].min
    score += 0.18 if role.to_s == "primary_user"

    meta = metadata.is_a?(Hash) ? metadata : {}
    feedback = meta["user_feedback"].is_a?(Hash) ? meta["user_feedback"] : {}
    status = feedback["real_person_status"].to_s
    score += 0.22 if status == "confirmed_real_person"
    score += 0.10 if status == "likely_real_person"
    score -= 0.45 if INACTIVE_MATCHING_STATUSES.include?(status)

    linked_usernames_count = Array(meta["linked_usernames"]).reject(&:blank?).size
    score += [ linked_usernames_count * 0.03, 0.15 ].min

    score.clamp(0.0, 1.0).round(3)
  end
end
