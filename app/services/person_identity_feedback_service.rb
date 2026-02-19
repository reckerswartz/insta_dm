class PersonIdentityFeedbackService
  class FeedbackError < StandardError; end

  MAX_LINKED_USERNAMES = 30
  FEEDBACK_VERSION = "v1".freeze

  def confirm_person!(person:, label: nil, real_person_status: "confirmed_real_person")
    raise FeedbackError, "Person record is required" unless person&.persisted?

    now = Time.current
    person.with_lock do
      metadata = normalize_metadata(person.metadata)
      feedback = normalize_feedback(metadata)
      feedback["real_person_status"] = normalize_real_person_status(real_person_status)
      feedback["last_action"] = "confirm_person"
      feedback["confirmed_count"] = feedback["confirmed_count"].to_i + 1
      feedback["last_action_at"] = now.iso8601
      feedback["feedback_version"] = FEEDBACK_VERSION
      metadata["user_feedback"] = feedback

      linked = Array(metadata["linked_usernames"]).map { |value| normalize_username(value) }.reject(&:blank?).uniq
      profile_username = normalize_username(person.instagram_profile&.username)
      linked << profile_username if profile_username.present? && person.role.to_s == "primary_user"
      metadata["linked_usernames"] = linked.first(MAX_LINKED_USERNAMES)

      person.label = label.to_s.strip if label.to_s.strip.present?
      person.metadata = metadata
      person.save!
      person.sync_identity_confidence!(timestamp: now)
      person
    end
  end

  def mark_incorrect!(person:, reason: nil)
    raise FeedbackError, "Person record is required" unless person&.persisted?

    now = Time.current
    person.with_lock do
      metadata = normalize_metadata(person.metadata)
      feedback = normalize_feedback(metadata)
      feedback["real_person_status"] = "incorrect"
      feedback["last_action"] = "mark_incorrect"
      feedback["last_action_at"] = now.iso8601
      feedback["incorrect_reason"] = reason.to_s.strip if reason.to_s.strip.present?
      feedback["feedback_version"] = FEEDBACK_VERSION
      metadata["user_feedback"] = feedback
      metadata["matching_disabled"] = true
      metadata["matching_disabled_reason"] = reason.to_s.strip.presence || "marked_incorrect"

      attrs = {
        role: person.role.to_s == "primary_user" ? "unknown" : person.role,
        metadata: metadata,
        canonical_embedding: nil
      }
      attrs[:canonical_embedding_vector] = nil if person.respond_to?(:canonical_embedding_vector=)
      person.update!(attrs)
      annotate_face_feedback!(person: person, status: "incorrect", reason: reason)
      person.sync_identity_confidence!(timestamp: now)
      person
    end
  end

  def link_profile_owner!(person:)
    raise FeedbackError, "Person record is required" unless person&.persisted?

    profile = person.instagram_profile
    raise FeedbackError, "Profile not found for person" unless profile

    now = Time.current
    InstagramStoryPerson.transaction do
      InstagramStoryPerson
        .where(instagram_profile_id: profile.id, role: "primary_user")
        .where.not(id: person.id)
        .update_all(role: "secondary_person", updated_at: now)

      person.with_lock do
        metadata = normalize_metadata(person.metadata)
        feedback = normalize_feedback(metadata)
        feedback["last_action"] = "link_profile_owner"
        feedback["last_action_at"] = now.iso8601
        feedback["real_person_status"] = "confirmed_real_person"
        feedback["owner_link_confirmed"] = true
        feedback["feedback_version"] = FEEDBACK_VERSION

        linked = Array(metadata["linked_usernames"]).map { |value| normalize_username(value) }.reject(&:blank?).uniq
        profile_username = normalize_username(profile.username)
        linked << profile_username if profile_username.present?

        metadata["linked_usernames"] = linked.first(MAX_LINKED_USERNAMES)
        metadata["user_feedback"] = feedback

        person.update!(
          role: "primary_user",
          label: person.label.to_s.presence || profile.username.to_s,
          metadata: metadata
        )
        person.sync_identity_confidence!(timestamp: now)
      end
    end

    person
  end

  def merge_people!(source_person:, target_person:)
    validate_merge!(source_person: source_person, target_person: target_person)

    now = Time.current
    InstagramStoryPerson.transaction do
      source_person.lock!
      target_person.lock!

      moved_post_faces = source_person.instagram_post_faces.update_all(
        instagram_story_person_id: target_person.id,
        role: target_person.role.to_s,
        updated_at: now
      )
      moved_story_faces = source_person.instagram_story_faces.update_all(
        instagram_story_person_id: target_person.id,
        role: target_person.role.to_s,
        updated_at: now
      )

      target_metadata = merge_person_metadata!(
        target_person: target_person,
        source_person: source_person,
        moved_post_faces: moved_post_faces,
        moved_story_faces: moved_story_faces,
        merged_at: now
      )

      target_person.update!(
        appearance_count: recompute_appearance_count(target_person),
        first_seen_at: [ target_person.first_seen_at, source_person.first_seen_at ].compact.min,
        last_seen_at: [ target_person.last_seen_at, source_person.last_seen_at ].compact.max,
        canonical_embedding: merged_embedding(target_person: target_person, source_person: source_person).presence,
        metadata: target_metadata
      )
      target_person.update_column(:canonical_embedding_vector, target_person.canonical_embedding.presence) if target_person.respond_to?(:canonical_embedding_vector=)
      target_person.sync_identity_confidence!(timestamp: now)

      source_metadata = normalize_metadata(source_person.metadata)
      source_feedback = normalize_feedback(source_metadata)
      source_feedback["last_action"] = "merged_into_person"
      source_feedback["last_action_at"] = now.iso8601
      source_feedback["merged_into_person_id"] = target_person.id
      source_feedback["feedback_version"] = FEEDBACK_VERSION
      source_metadata["user_feedback"] = source_feedback
      source_metadata["merged_into_person_id"] = target_person.id
      source_metadata["merged_at"] = now.iso8601
      source_metadata["matching_disabled"] = true
      source_metadata["matching_disabled_reason"] = "merged_into_#{target_person.id}"

      source_person.update!(
        role: "unknown",
        appearance_count: 0,
        canonical_embedding: nil,
        metadata: source_metadata
      )
      source_person.update_column(:canonical_embedding_vector, nil) if source_person.respond_to?(:canonical_embedding_vector=)
      source_person.sync_identity_confidence!(timestamp: now)
    end

    target_person
  end

  def separate_face!(person:, face:)
    raise FeedbackError, "Person record is required" unless person&.persisted?
    raise FeedbackError, "Face record is required" unless face&.persisted?
    raise FeedbackError, "Face is not linked to this person" unless face.instagram_story_person_id == person.id

    now = Time.current
    vector = normalize_vector(face.embedding)
    new_metadata = {
      "source" => "user_feedback_split",
      "separated_from_person_id" => person.id,
      "user_feedback" => {
        "real_person_status" => "unverified",
        "last_action" => "separate_face",
        "last_action_at" => now.iso8601,
        "feedback_version" => FEEDBACK_VERSION
      }
    }

    attrs = {
      instagram_account: person.instagram_account,
      instagram_profile: person.instagram_profile,
      role: "secondary_person",
      first_seen_at: now,
      last_seen_at: now,
      appearance_count: 1,
      canonical_embedding: vector.presence,
      metadata: new_metadata
    }
    attrs[:canonical_embedding_vector] = vector if person.respond_to?(:canonical_embedding_vector=) && vector.present?
    new_person = InstagramStoryPerson.create!(attrs)

    update_face_feedback_metadata!(face: face, status: "separated", reason: "split_from_person_#{person.id}", timestamp: now)
    face.update!(
      instagram_story_person: new_person,
      role: new_person.role
    )

    recompute_person_after_face_change!(person: person, timestamp: now)
    new_person.sync_identity_confidence!(timestamp: now)
    person.reload
    new_person
  end

  private

  def validate_merge!(source_person:, target_person:)
    raise FeedbackError, "Source person is required" unless source_person&.persisted?
    raise FeedbackError, "Target person is required" unless target_person&.persisted?
    raise FeedbackError, "Source and target person cannot be the same" if source_person.id == target_person.id

    if source_person.instagram_profile_id != target_person.instagram_profile_id ||
        source_person.instagram_account_id != target_person.instagram_account_id
      raise FeedbackError, "People can only be merged within the same account/profile"
    end
  end

  def annotate_face_feedback!(person:, status:, reason:)
    now = Time.current
    person.instagram_post_faces.find_each do |face|
      update_face_feedback_metadata!(face: face, status: status, reason: reason, timestamp: now)
    end
    person.instagram_story_faces.find_each do |face|
      update_face_feedback_metadata!(face: face, status: status, reason: reason, timestamp: now)
    end
  end

  def update_face_feedback_metadata!(face:, status:, reason:, timestamp:)
    metadata = normalize_metadata(face.metadata)
    feedback = metadata["user_feedback"].is_a?(Hash) ? metadata["user_feedback"].deep_dup : {}
    feedback["status"] = status.to_s
    feedback["reason"] = reason.to_s.strip if reason.to_s.strip.present?
    feedback["updated_at"] = timestamp.iso8601
    feedback["version"] = FEEDBACK_VERSION
    metadata["user_feedback"] = feedback
    face.update_columns(metadata: metadata, updated_at: timestamp)
  rescue StandardError
    nil
  end

  def merge_person_metadata!(target_person:, source_person:, moved_post_faces:, moved_story_faces:, merged_at:)
    target_metadata = normalize_metadata(target_person.metadata)
    source_metadata = normalize_metadata(source_person.metadata)

    target_feedback = normalize_feedback(target_metadata)
    source_feedback = normalize_feedback(source_metadata)
    target_feedback["last_action"] = "merge_person"
    target_feedback["last_action_at"] = merged_at.iso8601
    target_feedback["feedback_version"] = FEEDBACK_VERSION
    target_feedback["merge_count"] = target_feedback["merge_count"].to_i + 1
    target_metadata["user_feedback"] = target_feedback

    source_linked = Array(source_metadata["linked_usernames"]).map { |value| normalize_username(value) }.reject(&:blank?)
    target_linked = Array(target_metadata["linked_usernames"]).map { |value| normalize_username(value) }.reject(&:blank?)
    target_metadata["linked_usernames"] = (target_linked + source_linked).uniq.first(MAX_LINKED_USERNAMES)

    merge_history = Array(target_metadata["merge_history"]).select { |row| row.is_a?(Hash) }.first(40)
    merge_history << {
      "source_person_id" => source_person.id,
      "source_label" => source_person.label.to_s.presence,
      "source_real_person_status" => source_feedback["real_person_status"].to_s.presence,
      "moved_post_faces" => moved_post_faces.to_i,
      "moved_story_faces" => moved_story_faces.to_i,
      "merged_at" => merged_at.iso8601
    }.compact
    target_metadata["merge_history"] = merge_history.last(40)
    target_metadata
  end

  def merged_embedding(target_person:, source_person:)
    left = normalize_vector(target_person.canonical_embedding)
    right = normalize_vector(source_person.canonical_embedding)
    return left if right.empty?
    return right if left.empty?

    left_count = [ target_person.appearance_count.to_i, 1 ].max
    right_count = [ source_person.appearance_count.to_i, 1 ].max
    combined = left.each_with_index.map do |value, idx|
      ((value * left_count) + (right[idx] * right_count)) / (left_count + right_count).to_f
    end
    normalize_vector(combined)
  end

  def recompute_person_after_face_change!(person:, timestamp:)
    remaining_count = recompute_appearance_count(person)
    metadata = normalize_metadata(person.metadata)
    feedback = normalize_feedback(metadata)
    feedback["last_action"] = "separate_face_applied"
    feedback["last_action_at"] = timestamp.iso8601
    feedback["feedback_version"] = FEEDBACK_VERSION
    metadata["user_feedback"] = feedback

    attrs = {
      appearance_count: remaining_count,
      metadata: metadata
    }

    if remaining_count <= 0
      attrs[:canonical_embedding] = nil
      attrs[:canonical_embedding_vector] = nil if person.respond_to?(:canonical_embedding_vector=)
    end

    person.update!(attrs)
    person.sync_identity_confidence!(timestamp: timestamp)
  end

  def recompute_appearance_count(person)
    count = person.instagram_post_faces.count + person.instagram_story_faces.count
    count.positive? ? count : 0
  end

  def normalize_real_person_status(value)
    token = value.to_s.strip.presence || "confirmed_real_person"
    return "confirmed_real_person" if token == "confirmed"
    return "likely_real_person" if token == "likely"

    token
  end

  def normalize_metadata(value)
    value.is_a?(Hash) ? value.deep_dup : {}
  end

  def normalize_feedback(metadata)
    value = metadata["user_feedback"]
    value.is_a?(Hash) ? value.deep_dup : {}
  end

  def normalize_username(value)
    token = value.to_s.strip.downcase
    return nil if token.blank?

    token = token.delete_prefix("@")
    token = token.gsub(/[^a-z0-9._]/, "")
    return nil unless token.length.between?(2, 30)

    token
  end

  def normalize_vector(values)
    vector = Array(values).map(&:to_f)
    return [] if vector.empty?

    norm = Math.sqrt(vector.sum { |value| value * value })
    return [] if norm <= 0.0

    vector.map { |value| value / norm }
  end
end
