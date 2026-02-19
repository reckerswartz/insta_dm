class FaceIdentityResolutionService
  MIN_PRIMARY_APPEARANCES = 3
  MIN_PRIMARY_RATIO = 0.60
  FREQUENT_COLLABORATOR_CO_APPEARANCES = 3
  VERY_FREQUENT_COLLABORATOR_CO_APPEARANCES = 6

  RESERVED_USERNAMES = %w[
    instagram
    stories
    p
    reel
    reels
    tv
    explore
    accounts
    direct
    www
    com
  ].freeze

  def resolve_for_post!(post:, extracted_usernames: [], content_summary: {})
    return { skipped: true, reason: "post_missing" } unless post&.persisted?
    return { skipped: true, reason: "profile_missing" } unless post.instagram_profile

    resolve_for_source!(
      source: post,
      source_type: "post",
      profile: post.instagram_profile,
      account: post.instagram_account,
      extracted_usernames: extracted_usernames,
      content_summary: content_summary
    )
  end

  def resolve_for_story!(story:, extracted_usernames: [], content_summary: {})
    return { skipped: true, reason: "story_missing" } unless story&.persisted?
    return { skipped: true, reason: "profile_missing" } unless story.instagram_profile

    resolve_for_source!(
      source: story,
      source_type: "story",
      profile: story.instagram_profile,
      account: story.instagram_account,
      extracted_usernames: extracted_usernames,
      content_summary: content_summary
    )
  end

  private

  def resolve_for_source!(source:, source_type:, profile:, account:, extracted_usernames:, content_summary:)
    faces = source_faces(source: source, source_type: source_type)
    usernames = collect_usernames(
      profile: profile,
      source: source,
      extracted_usernames: extracted_usernames,
      content_summary: content_summary
    )

    participants, unknown_face_count = build_participants(faces)
    apply_username_links!(participants: participants, usernames: usernames, profile: profile)

    stats = profile_face_stats(profile: profile)
    primary_identity = promote_primary_identity!(profile: profile, stats: stats)
    participants = refresh_participants_with_latest_people(participants: participants, profile: profile)
    apply_username_links!(participants: participants, usernames: usernames, profile: profile)
    sync_source_face_roles!(source: source, source_type: source_type)

    collaborator_index = build_collaborator_index(profile: profile, primary_person_id: primary_identity[:person_id])
    update_collaborator_relationships!(profile: profile, collaborator_index: collaborator_index)

    username_matches = map_usernames_to_people(profile: profile, usernames: usernames)
    participants = enrich_participants(
      participants: participants,
      stats: stats,
      collaborator_index: collaborator_index
    )
    participants_payload = participants.map { |row| row.except(:person) }

    summary_text = build_summary_text(
      profile: profile,
      participants: participants_payload,
      primary_identity: primary_identity,
      usernames: usernames,
      unknown_face_count: unknown_face_count
    )

    summary = {
      source_type: source_type,
      source_id: source.id,
      extracted_usernames: usernames,
      unknown_face_count: unknown_face_count,
      participants: participants_payload,
      primary_identity: primary_identity,
      username_face_matches: username_matches,
      participant_summary_text: summary_text,
      resolved_at: Time.current.iso8601
    }

    persist_profile_face_identity!(
      profile: profile,
      primary_identity: primary_identity,
      collaborator_index: collaborator_index,
      username_matches: username_matches
    )
    persist_source_summary!(source: source, source_type: source_type, summary: summary)

    { skipped: false, summary: summary }
  rescue StandardError => e
    {
      skipped: true,
      reason: "face_identity_resolution_error",
      error: e.message.to_s
    }
  end

  def source_faces(source:, source_type:)
    case source_type
    when "post"
      source.instagram_post_faces.includes(:instagram_story_person).to_a
    when "story"
      source.instagram_story_faces.includes(:instagram_story_person).to_a
    else
      []
    end
  end

  def collect_usernames(profile:, source:, extracted_usernames:, content_summary:)
    rows = []
    rows.concat(Array(extracted_usernames))

    content = content_summary.is_a?(Hash) ? content_summary : {}
    rows.concat(Array(content[:mentions] || content["mentions"]))
    rows.concat(Array(content[:profile_handles] || content["profile_handles"]))
    rows.concat(extract_usernames_from_text(content[:ocr_text] || content["ocr_text"]))

    metadata = source.metadata.is_a?(Hash) ? source.metadata : {}
    rows.concat(Array(metadata["mentions"]))
    rows.concat(Array(metadata["profile_handles"]))
    rows.concat(extract_usernames_from_text(metadata["ocr_text"]))
    rows.concat(extract_usernames_from_url(metadata["story_url"]))
    rows.concat(extract_usernames_from_url(metadata["permalink"]))

    if metadata["story_ref"].to_s.present?
      rows << metadata["story_ref"].to_s.delete_suffix(":")
    end

    username = normalize_username(profile.username)
    rows << username if username.present?

    rows
      .map { |value| normalize_username(value) }
      .reject(&:blank?)
      .uniq
      .first(40)
  end

  def extract_usernames_from_text(text)
    value = text.to_s
    return [] if value.blank?

    usernames = []
    value.scan(/@([a-zA-Z0-9._]{2,30})/) { |match| usernames << match.first }
    value.scan(/\b([a-zA-Z0-9._]{3,30})\b/) do |match|
      token = match.first.to_s
      next unless username_like_token?(token)
      usernames << token
    end
    usernames
  end

  def extract_usernames_from_url(url)
    value = url.to_s
    return [] if value.blank?

    rows = []
    if (match = value.match(%r{instagram\.com/stories/([a-zA-Z0-9._]+)/?}i))
      rows << match[1]
    end
    if (match = value.match(%r{instagram\.com/([a-zA-Z0-9._]+)/?}i))
      candidate = match[1].to_s
      rows << candidate unless RESERVED_USERNAMES.include?(candidate.downcase)
    end
    rows
  end

  def build_participants(faces)
    unknown = 0
    participants = Array(faces).map do |face|
      person = face.instagram_story_person
      unless person
        unknown += 1
        next
      end

      {
        person: person,
        person_id: person.id,
        role: person.role.to_s,
        label: person.label.to_s.presence,
        match_similarity: face.match_similarity.to_f,
        detector_confidence: face.detector_confidence.to_f,
        linked_usernames: linked_usernames(person)
      }
    end.compact

    [ participants, unknown ]
  end

  def apply_username_links!(participants:, usernames:, profile:)
    return if participants.empty?
    return if usernames.empty?

    primary_username = normalize_username(profile.username)
    primary_participant = participants.find { |row| row[:role] == "primary_user" }

    if primary_participant && primary_username.present?
      update_person_usernames!(primary_participant[:person], [ primary_username ])
    end

    external = usernames.reject { |value| value == primary_username }
    return if external.empty?

    by_person_id = participants.index_by { |row| row[:person_id] }
    alias_map = username_alias_index(profile: profile)

    external.each do |username|
      matched_person_id = alias_map[username]
      if matched_person_id && by_person_id[matched_person_id]
        update_person_usernames!(by_person_id[matched_person_id][:person], [ username ])
        next
      end

      non_primary = participants.reject { |row| row[:role] == "primary_user" }
      next unless non_primary.length == 1

      update_person_usernames!(non_primary.first[:person], [ username ])
    end
  end

  def update_person_usernames!(person, usernames)
    rows = Array(usernames).map { |value| normalize_username(value) }.reject(&:blank?).uniq
    return if rows.empty?

    meta = person.metadata.is_a?(Hash) ? person.metadata.deep_dup : {}
    linked = Array(meta["linked_usernames"]).map { |value| normalize_username(value) }.reject(&:blank?)
    updated = (linked + rows).uniq.first(30)
    return if updated == linked

    observations = meta["username_observations"].is_a?(Hash) ? meta["username_observations"].deep_dup : {}
    rows.each { |username| observations[username] = observations[username].to_i + 1 }

    meta["linked_usernames"] = updated
    meta["username_observations"] = observations
    meta["last_username_linked_at"] = Time.current.iso8601
    person.update_columns(metadata: meta, updated_at: Time.current)
  end

  def profile_face_stats(profile:)
    story_counts = InstagramStoryFace
      .joins(:instagram_story)
      .where(instagram_stories: { instagram_profile_id: profile.id })
      .where.not(instagram_story_person_id: nil)
      .group(:instagram_story_person_id)
      .count

    post_counts = InstagramPostFace
      .joins(:instagram_profile_post)
      .where(instagram_profile_posts: { instagram_profile_id: profile.id })
      .where.not(instagram_story_person_id: nil)
      .group(:instagram_story_person_id)
      .count

    counts = story_counts.merge(post_counts) { |_id, left, right| left.to_i + right.to_i }
    total = counts.values.sum

    {
      person_counts: counts,
      total_faces: total,
      people_by_id: profile.instagram_story_people.where(id: counts.keys).index_by(&:id)
    }
  end

  def promote_primary_identity!(profile:, stats:)
    counts = stats[:person_counts]
    total = stats[:total_faces].to_i
    return empty_primary_identity if counts.empty? || total <= 0

    top_person_id, top_count = counts.max_by { |_id, count| count.to_i }
    top_person = stats[:people_by_id][top_person_id]
    return empty_primary_identity unless top_person

    ratio = top_count.to_f / total.to_f
    confirmed = top_count.to_i >= MIN_PRIMARY_APPEARANCES && ratio >= MIN_PRIMARY_RATIO

    primary_person = profile.instagram_story_people.find_by(role: "primary_user")

    if confirmed
      InstagramStoryPerson.where(instagram_profile_id: profile.id, role: "primary_user").where.not(id: top_person.id).update_all(role: "secondary_person", updated_at: Time.current)

      metadata = top_person.metadata.is_a?(Hash) ? top_person.metadata.deep_dup : {}
      metadata["primary_identity"] = {
        "confirmed" => true,
        "dominance_ratio" => ratio.round(4),
        "appearance_count" => top_count.to_i,
        "updated_at" => Time.current.iso8601
      }

      top_person.update!(
        role: "primary_user",
        label: top_person.label.to_s.presence || profile.username.to_s,
        metadata: metadata
      )
      primary_person = top_person
    end

    candidate = primary_person || top_person
    {
      person_id: candidate.id,
      confirmed: confirmed,
      role: candidate.role,
      label: candidate.label.to_s.presence,
      appearance_count: counts[candidate.id].to_i,
      total_faces: total,
      dominance_ratio: (counts[candidate.id].to_f / total.to_f).round(4),
      linked_usernames: linked_usernames(candidate),
      bio_context: bio_context_tokens(profile: profile)
    }
  end

  def build_collaborator_index(profile:, primary_person_id:)
    return {} if primary_person_id.blank?

    story_rows = InstagramStoryFace
      .joins(:instagram_story)
      .where(instagram_stories: { instagram_profile_id: profile.id })
      .where.not(instagram_story_person_id: nil)
      .pluck(:instagram_story_id, :instagram_story_person_id)

    post_rows = InstagramPostFace
      .joins(:instagram_profile_post)
      .where(instagram_profile_posts: { instagram_profile_id: profile.id })
      .where.not(instagram_story_person_id: nil)
      .pluck(:instagram_profile_post_id, :instagram_story_person_id)

    collaborator_counts = Hash.new(0)

    story_rows.group_by(&:first).each_value do |rows|
      people = rows.map(&:last).uniq
      next unless people.include?(primary_person_id)
      people.reject { |person_id| person_id == primary_person_id }.each { |person_id| collaborator_counts[person_id] += 1 }
    end

    post_rows.group_by(&:first).each_value do |rows|
      people = rows.map(&:last).uniq
      next unless people.include?(primary_person_id)
      people.reject { |person_id| person_id == primary_person_id }.each { |person_id| collaborator_counts[person_id] += 1 }
    end

    collaborator_counts.transform_values do |count|
      {
        co_appearances_with_primary: count.to_i,
        relationship: relationship_for_coappearance(count.to_i)
      }
    end
  end

  def update_collaborator_relationships!(profile:, collaborator_index:)
    return if collaborator_index.empty?

    profile.instagram_story_people.where(id: collaborator_index.keys).find_each do |person|
      data = collaborator_index[person.id] || {}
      metadata = person.metadata.is_a?(Hash) ? person.metadata.deep_dup : {}
      metadata["relationship"] = data[:relationship]
      metadata["co_appearances_with_primary"] = data[:co_appearances_with_primary].to_i
      metadata["relationship_updated_at"] = Time.current.iso8601
      person.update_columns(metadata: metadata, updated_at: Time.current)
    end
  end

  def map_usernames_to_people(profile:, usernames:)
    return [] if usernames.empty?

    alias_map = username_alias_index(profile: profile)
    people = profile.instagram_story_people.where(id: alias_map.values.uniq).index_by(&:id)

    usernames.filter_map do |username|
      person_id = alias_map[username]
      next unless person_id
      person = people[person_id]
      next unless person

      {
        username: username,
        person_id: person.id,
        role: person.role,
        label: person.label.to_s.presence,
        relationship: person.metadata.is_a?(Hash) ? person.metadata["relationship"].to_s.presence : nil
      }.compact
    end
  end

  def username_alias_index(profile:)
    map = {}

    profile.instagram_story_people.find_each do |person|
      aliases = linked_usernames(person)
      label_alias = normalize_username(person.label)
      aliases << label_alias if label_alias.present?

      aliases.uniq.each do |alias_name|
        map[alias_name] ||= person.id
      end
    end

    map
  end

  def enrich_participants(participants:, stats:, collaborator_index:)
    counts = stats[:person_counts]

    participants.map do |row|
      person = row[:person]
      collaborator = collaborator_index[person.id] || {}
      appearances = counts[person.id].to_i
      role = person.role.to_s
      row.merge(
        role: role,
        owner_match: role == "primary_user",
        recurring_face: appearances > 1,
        appearances: counts[person.id].to_i,
        relationship: collaborator[:relationship] || person.metadata&.dig("relationship"),
        co_appearances_with_primary: collaborator[:co_appearances_with_primary].to_i,
        linked_usernames: linked_usernames(person)
      )
    end.uniq { |row| [ row[:person_id], row[:match_similarity].round(4), row[:detector_confidence].round(4) ] }
  end

  def refresh_participants_with_latest_people(participants:, profile:)
    ids = participants.map { |row| row[:person_id] }.compact.uniq
    return participants if ids.empty?

    by_id = profile.instagram_story_people.where(id: ids).index_by(&:id)
    participants.map do |row|
      latest = by_id[row[:person_id]]
      next row unless latest

      row.merge(
        person: latest,
        role: latest.role.to_s,
        label: latest.label.to_s.presence,
        linked_usernames: linked_usernames(latest)
      )
    end
  end

  def build_summary_text(profile:, participants:, primary_identity:, usernames:, unknown_face_count:)
    parts = []

    if primary_identity[:person_id].present?
      state = primary_identity[:confirmed] ? "confirmed" : "candidate"
      parts << "Primary identity #{state}: #{primary_identity[:label] || profile.username}"
    end

    if participants.any?
      participant_text = participants.first(8).map do |row|
        base = row[:label] || "person_#{row[:person_id]}"
        rel = row[:relationship].to_s.presence
        aliases = Array(row[:linked_usernames]).first(2)
        detail = []
        detail << rel if rel.present?
        detail << "aka #{aliases.join('/') }" if aliases.any?
        detail << "seen #{row[:appearances]}x" if row[:appearances].to_i.positive?
        detail.empty? ? base : "#{base} (#{detail.join(', ')})"
      end
      parts << "Participants: #{participant_text.join('; ')}"
    end

    parts << "Referenced usernames: #{usernames.join(', ')}" if usernames.any?
    parts << "Unknown faces: #{unknown_face_count}" if unknown_face_count.to_i.positive?

    text = parts.join(". ").strip
    text.presence || "No identifiable participants found."
  end

  def persist_profile_face_identity!(profile:, primary_identity:, collaborator_index:, username_matches:)
    record = InstagramProfileBehaviorProfile.find_or_initialize_by(instagram_profile: profile)

    summary = record.behavioral_summary.is_a?(Hash) ? record.behavioral_summary.deep_dup : {}
    summary["face_identity_profile"] = primary_identity
    summary["related_individuals"] = collaborator_index.map do |person_id, row|
      person = profile.instagram_story_people.find_by(id: person_id)
      {
        person_id: person_id,
        role: person&.role,
        label: person&.label.to_s.presence,
        relationship: row[:relationship],
        co_appearances_with_primary: row[:co_appearances_with_primary].to_i,
        linked_usernames: person ? linked_usernames(person).first(6) : []
      }.compact
    end
    summary["known_username_matches"] = username_matches.first(20)

    metadata = record.metadata.is_a?(Hash) ? record.metadata.deep_dup : {}
    metadata["face_identity_updated_at"] = Time.current.iso8601
    metadata["face_identity_version"] = "v1"

    record.activity_score = record.activity_score.to_f if record.activity_score.present?
    record.behavioral_summary = summary
    record.metadata = metadata
    record.save!
  end

  def persist_source_summary!(source:, source_type:, summary:)
    metadata = source.metadata.is_a?(Hash) ? source.metadata.deep_dup : {}
    metadata["face_identity"] = summary
    metadata["participant_summary"] = summary[:participant_summary_text].to_s
    metadata["participants"] = Array(summary[:participants]).first(12)

    source.update_columns(metadata: metadata, updated_at: Time.current)

    return unless source_type == "story"
    return unless source.respond_to?(:source_event)

    event = source.source_event
    return unless event

    event_meta = event.metadata.is_a?(Hash) ? event.metadata.deep_dup : {}
    event_meta["face_identity"] = summary
    event_meta["participant_summary"] = summary[:participant_summary_text].to_s
    event.update_columns(metadata: event_meta, updated_at: Time.current)
  rescue StandardError
    nil
  end

  def sync_source_face_roles!(source:, source_type:)
    case source_type
    when "post"
      source.instagram_post_faces.includes(:instagram_story_person).find_each do |face|
        next unless face.instagram_story_person
        next if face.role.to_s == face.instagram_story_person.role.to_s

        face.update_columns(role: face.instagram_story_person.role.to_s, updated_at: Time.current)
      end
    when "story"
      source.instagram_story_faces.includes(:instagram_story_person).find_each do |face|
        next unless face.instagram_story_person
        next if face.role.to_s == face.instagram_story_person.role.to_s

        face.update_columns(role: face.instagram_story_person.role.to_s, updated_at: Time.current)
      end
    end
  rescue StandardError
    nil
  end

  def linked_usernames(person)
    data = person.metadata.is_a?(Hash) ? person.metadata : {}
    Array(data["linked_usernames"]).map { |value| normalize_username(value) }.reject(&:blank?).uniq.first(20)
  end

  def relationship_for_coappearance(count)
    return "very_frequent_collaborator" if count >= VERY_FREQUENT_COLLABORATOR_CO_APPEARANCES
    return "frequent_collaborator" if count >= FREQUENT_COLLABORATOR_CO_APPEARANCES
    return "occasional_collaborator" if count.positive?

    "unknown"
  end

  def bio_context_tokens(profile:)
    text = [ profile.display_name, profile.bio ].join(" ").downcase
    return [] if text.blank?

    stopwords = %w[the and for with this that from your our you are]
    text.scan(/[a-z0-9_]+/)
      .reject { |token| token.length < 3 || stopwords.include?(token) }
      .uniq
      .first(20)
  end

  def empty_primary_identity
    {
      person_id: nil,
      confirmed: false,
      role: "unknown",
      label: nil,
      appearance_count: 0,
      total_faces: 0,
      dominance_ratio: 0.0,
      linked_usernames: [],
      bio_context: []
    }
  end

  def normalize_username(value)
    token = value.to_s.strip.downcase
    return nil if token.blank?

    token = token.sub(%r{https?://(www\.)?instagram\.com/}i, "")
    token = token.split("/").first.to_s
    token = token.delete_prefix("@").delete_prefix("#")
    token = token.delete_suffix(":")
    token = token.gsub(/[^a-z0-9._]/, "")
    return nil if token.blank?
    return nil if RESERVED_USERNAMES.include?(token)
    return nil unless token.length.between?(2, 30)

    token
  end

  def username_like_token?(token)
    value = token.to_s.downcase
    return false unless value.match?(/\A[a-z0-9._]{3,30}\z/)
    return false if RESERVED_USERNAMES.include?(value)
    return false if value.include?("instagram.com")

    value.include?("_") || value.include?(".")
  end
end
