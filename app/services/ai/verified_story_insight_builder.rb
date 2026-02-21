module Ai
  class VerifiedStoryInsightBuilder
    MIN_OCR_BLOCK_CONFIDENCE = 0.35
    MIN_OBJECT_CONFIDENCE = 0.30
    MIN_SIGNAL_SCORE_FOR_COMMENT = 3
    MIN_OWNER_ALIGNMENT_CONFIDENCE = 0.58

    OCR_USERNAME_REGEX = /@([a-zA-Z0-9._]{2,30})/
    BARE_USERNAME_REGEX = /\b([a-zA-Z0-9._]{3,30})\b/
    RESHARE_PATTERNS = [
      /\brepost\b/i,
      /\breshare\b/i,
      /\bshared\s+from\b/i,
      /\bvia\s+@?[a-z0-9._]+\b/i,
      /\bcredit(?:s)?\b/i,
      /\boriginal\s+by\b/i
    ].freeze
    MEME_PATTERNS = [
      /\bmemes?\b/i,
      /\bi know nobody gave you\b/i,
      /\bdon'?t worry\b/i,
      /\bwhen you\b/i
    ].freeze
    RESERVED_IG_SEGMENTS = %w[stories p reel reels tv explore accounts direct v].freeze

    def initialize(profile:, local_story_intelligence:, metadata:)
      @profile = profile
      @raw = local_story_intelligence.is_a?(Hash) ? local_story_intelligence : {}
      @metadata = metadata.is_a?(Hash) ? metadata : {}
    end

    def build
      verified_story_facts = build_verified_story_facts
      ownership_classification = classify_ownership(verified_story_facts: verified_story_facts)
      generation_policy = build_generation_policy(
        verified_story_facts: verified_story_facts,
        ownership_classification: ownership_classification
      )

      {
        verified_story_facts: verified_story_facts,
        ownership_classification: ownership_classification,
        generation_policy: generation_policy,
        validated_at: Time.current.iso8601
      }
    end

    private

    def build_verified_story_facts
      ocr_blocks = normalize_ocr_blocks(@raw[:ocr_blocks] || @raw["ocr_blocks"])
      object_detections = normalize_object_detections(@raw[:object_detections] || @raw["object_detections"])
      scenes = normalize_scenes(@raw[:scenes] || @raw["scenes"])

      ocr_text = normalize_text(@raw[:ocr_text] || @raw["ocr_text"], max: 800)
      if ocr_blocks.any?
        ocr_text = ocr_blocks.map { |row| row[:text] }.join("\n").presence || ocr_text
      end

      transcript = normalize_text(@raw[:transcript] || @raw["transcript"], max: 800)
      mentions = normalize_handle_array(@raw[:mentions] || @raw["mentions"], prefix: "@")
      hashtags = normalize_handle_array(@raw[:hashtags] || @raw["hashtags"], prefix: "#")
      objects = normalize_objects(@raw[:objects] || @raw["objects"], object_detections: object_detections)
      topics = normalize_topics(@raw[:topics] || @raw["topics"], objects: objects, hashtags: hashtags)
      faces = normalize_faces
      detected_usernames = detect_usernames(
        mentions: mentions,
        profile_handles: @raw[:profile_handles] || @raw["profile_handles"],
        ocr_text: ocr_text,
        transcript: transcript,
        metadata: @metadata
      )
      source_profile_references = extract_source_profile_references(metadata: @metadata)
      source_profile_ids = extract_source_profile_ids(metadata: @metadata)
      reshare_hits = detect_reshare_indicators(
        ocr_text: ocr_text,
        transcript: transcript,
        metadata: @metadata
      )
      meme_markers = detect_meme_markers(
        ocr_text: ocr_text,
        transcript: transcript,
        metadata: @metadata
      )
      identity_verification = build_identity_verification(
        faces: faces,
        topics: topics,
        detected_usernames: detected_usernames,
        source_profile_references: source_profile_references
      )

      signal_score = score_verified_signals(
        ocr_text: ocr_text,
        transcript: transcript,
        objects: objects,
        object_detections: object_detections,
        scenes: scenes,
        hashtags: hashtags,
        mentions: mentions,
        faces: faces
      )

      {
        source: @raw[:source].to_s.presence || @raw["source"].to_s.presence || "unknown",
        reason: @raw[:reason].to_s.presence || @raw["reason"].to_s.presence,
        ocr_text: ocr_text,
        ocr_blocks: ocr_blocks.first(30),
        transcript: transcript,
        object_detections: object_detections.first(30),
        objects: objects.first(20),
        scenes: scenes.first(20),
        hashtags: hashtags.first(20),
        mentions: mentions.first(20),
        profile_handles: Array(@raw[:profile_handles] || @raw["profile_handles"]).map(&:to_s).first(20),
        topics: topics.first(20),
        detected_usernames: detected_usernames.first(20),
        source_profile_references: source_profile_references.first(20),
        source_profile_ids: source_profile_ids.first(20),
        reshare_indicators: reshare_hits.first(12),
        meme_markers: meme_markers.first(12),
        media_type: @metadata["media_type"].to_s.presence,
        faces: faces,
        face_count: faces[:total_count].to_i,
        people: faces[:people].first(12),
        identity_verification: identity_verification,
        signal_score: signal_score
      }
    end

    def classify_ownership(verified_story_facts:)
      profile_username = normalize_username(@profile&.username)
      usernames = Array(verified_story_facts[:detected_usernames]).map { |value| normalize_username(value) }.reject(&:blank?).uniq
      external_usernames = usernames.reject { |value| value == profile_username }
      profile_username_detected = profile_username.present? && usernames.include?(profile_username)
      source_profile_references = Array(verified_story_facts[:source_profile_references]).map { |value| normalize_username(value) }.reject(&:blank?).uniq
      external_source_refs = source_profile_references.reject { |value| value == profile_username }
      face_data = verified_story_facts[:faces].is_a?(Hash) ? verified_story_facts[:faces] : {}
      primary_faces = face_data[:primary_user_count].to_i
      secondary_faces = face_data[:secondary_person_count].to_i
      identity_verification = verified_story_facts[:identity_verification].is_a?(Hash) ? verified_story_facts[:identity_verification] : {}
      owner_likelihood = identity_verification[:owner_likelihood].to_s
      identity_confidence = identity_verification[:confidence].to_f
      non_primary_faces_without_primary = secondary_faces.positive? && primary_faces <= 0
      reshare_hits = Array(verified_story_facts[:reshare_indicators]).map(&:to_s)
      meme_markers = Array(verified_story_facts[:meme_markers]).map(&:to_s)
      third_party_link = third_party_profile_link_detected?(profile_username: profile_username, metadata: @metadata)
      share_status = infer_share_status(
        profile_username_detected: profile_username_detected,
        external_usernames: external_usernames,
        external_source_refs: external_source_refs,
        reshare_hits: reshare_hits,
        meme_markers: meme_markers
      )

      reason_codes = []
      reason_codes << "external_usernames_detected" if external_usernames.any?
      reason_codes << "external_source_profile_reference_detected" if external_source_refs.any?
      reason_codes << "profile_username_not_detected" if profile_username.present? && !profile_username_detected
      reason_codes << "non_primary_faces_detected" if non_primary_faces_without_primary
      reason_codes << "reshare_indicators_detected" if reshare_hits.any?
      reason_codes << "meme_markers_detected" if meme_markers.any?
      reason_codes << "third_party_profile_link_detected" if third_party_link
      reason_codes << "identity_likelihood_low" if owner_likelihood == "low"
      reason_codes << "identity_likelihood_high" if owner_likelihood == "high"
      reason_codes << "identity_confidence_low" if identity_confidence.positive? && identity_confidence < 0.45
      reason_codes << "share_status_#{share_status}" if share_status != "unknown"

      signal_score = verified_story_facts[:signal_score].to_i
      label = "owned_by_profile"
      decision = "allow_comment"

      if signal_score < MIN_SIGNAL_SCORE_FOR_COMMENT
        label = "insufficient_evidence"
        decision = "skip_comment"
        reason_codes << "insufficient_verified_signals"
      elsif meme_markers.any? && external_usernames.any?
        label = "meme_reshare"
        decision = "skip_comment"
      elsif meme_markers.any? && !profile_username_detected
        label = "meme_reshare"
        decision = "skip_comment"
      elsif share_status == "reshared" && external_usernames.any?
        label = "reshare"
        decision = "skip_comment"
      elsif reshare_hits.any? || third_party_link
        label = "reshare"
        decision = "skip_comment"
      elsif external_source_refs.any? && !profile_username_detected
        label = "third_party_content"
        decision = "skip_comment"
      elsif external_usernames.any? && !profile_username_detected && non_primary_faces_without_primary
        label = "third_party_content"
        decision = "skip_comment"
      elsif external_usernames.any? && !profile_username_detected && signal_score <= 3
        label = "third_party_content"
        decision = "skip_comment"
      elsif non_primary_faces_without_primary && signal_score <= 2
        label = "unrelated_post"
        decision = "skip_comment"
      elsif owner_likelihood == "low" && (external_usernames.any? || external_source_refs.any? || non_primary_faces_without_primary)
        label = "third_party_content"
        decision = "skip_comment"
      elsif owner_likelihood == "high" && identity_confidence >= MIN_OWNER_ALIGNMENT_CONFIDENCE && share_status == "unknown" && reshare_hits.empty? && meme_markers.empty?
        label = "owned_by_profile"
        decision = "allow_comment"
      end

      {
        label: label,
        decision: decision,
        confidence: ownership_confidence(
          label: label,
          reason_codes: reason_codes,
          signal_score: signal_score
        ),
        reason_codes: reason_codes.uniq,
        profile_username_detected: profile_username_detected,
        share_status: share_status,
        source_profile_references: source_profile_references.first(10),
        source_profile_ids: Array(verified_story_facts[:source_profile_ids]).map(&:to_s).first(10),
        detected_external_usernames: external_usernames.first(10),
        reshare_indicators: reshare_hits.first(10),
        meme_markers: meme_markers.first(10),
        identity_verification: identity_verification,
        face_evidence: {
          primary_user_count: primary_faces,
          secondary_person_count: secondary_faces,
          total_count: face_data[:total_count].to_i
        },
        summary: ownership_summary(
          label: label,
          external_usernames: external_usernames,
          external_source_refs: external_source_refs,
          reshare_hits: reshare_hits,
          meme_markers: meme_markers,
          primary_faces: primary_faces,
          secondary_faces: secondary_faces,
          signal_score: signal_score
        )
      }
    end

    def build_generation_policy(verified_story_facts:, ownership_classification:)
      allow_comment = ownership_classification[:decision].to_s == "allow_comment"
      allow_auto_post = allow_comment
      manual_review_required = false
      manual_review_reason = nil
      identity_verification = verified_story_facts[:identity_verification].is_a?(Hash) ? verified_story_facts[:identity_verification] : {}
      if allow_comment &&
          ownership_classification[:label].to_s == "owned_by_profile" &&
          identity_verification[:owner_likelihood].to_s == "low" &&
          identity_verification[:confidence].to_f < MIN_OWNER_ALIGNMENT_CONFIDENCE
        allow_comment = true
        allow_auto_post = false
        manual_review_required = true
        manual_review_reason = "identity_likelihood_low"
      end

      if ownership_classification[:label].to_s == "insufficient_evidence"
        allow_comment = true
        allow_auto_post = false
        manual_review_required = true
        manual_review_reason ||= "insufficient_verified_signals"
      end
      reason_code = if allow_comment
        "verified_context_available"
      else
        ownership_classification[:reason_codes].first.to_s.presence || "policy_blocked"
      end
      reason = if allow_comment
        "Verified context is sufficient for grounded generation."
      else
        ownership_classification[:summary].to_s.presence || "Insufficient or irrelevant verified context for safe comment generation."
      end

      {
        allow_comment: allow_comment,
        allow_auto_post: allow_auto_post,
        manual_review_required: manual_review_required,
        manual_review_reason: manual_review_reason,
        reason_code: reason_code,
        reason: reason,
        classification: ownership_classification[:label].to_s,
        signal_score: verified_story_facts[:signal_score].to_i,
        minimum_signal_score: MIN_SIGNAL_SCORE_FOR_COMMENT,
        owner_likelihood: identity_verification[:owner_likelihood].to_s,
        identity_confidence: identity_verification[:confidence].to_f.round(2),
        source: "verified_story_insight_builder"
      }
    end

    def normalize_ocr_blocks(value)
      Array(value).filter_map do |row|
        next unless row.is_a?(Hash)
        text = normalize_text(row[:text] || row["text"], max: 180)
        next if text.blank?
        confidence = (row[:confidence] || row["confidence"]).to_f
        next if confidence.positive? && confidence < MIN_OCR_BLOCK_CONFIDENCE

        {
          text: text,
          confidence: confidence,
          source: (row[:source] || row["source"]).to_s.presence || "ocr",
          timestamp: row[:timestamp] || row["timestamp"]
        }.compact
      end
    end

    def normalize_object_detections(value)
      Array(value).filter_map do |row|
        next unless row.is_a?(Hash)
        label = normalize_text(row[:label] || row["label"] || row[:description] || row["description"], max: 80)&.downcase
        next if label.blank?
        confidence = (row[:confidence] || row["confidence"] || row[:score] || row["score"] || row[:max_confidence] || row["max_confidence"]).to_f
        next if confidence.positive? && confidence < MIN_OBJECT_CONFIDENCE

        {
          label: label,
          confidence: confidence,
          timestamps: Array(row[:timestamps] || row["timestamps"]).map(&:to_f).first(20)
        }
      end.uniq { |row| [row[:label], row[:timestamps]] }
    end

    def normalize_scenes(value)
      Array(value).filter_map do |row|
        next unless row.is_a?(Hash)
        scene_type = normalize_text(row[:type] || row["type"], max: 60)
        next if scene_type.blank?

        {
          type: scene_type.downcase,
          timestamp: row[:timestamp] || row["timestamp"],
          correlation: row[:correlation] || row["correlation"]
        }.compact
      end
    end

    def normalize_objects(raw_objects, object_detections:)
      from_objects = Array(raw_objects).map { |row| normalize_text(row, max: 80) }.compact.map(&:downcase)
      from_detections = Array(object_detections).map { |row| row[:label].to_s.downcase }.reject(&:blank?)
      (from_objects + from_detections).uniq.first(40)
    end

    def normalize_topics(raw_topics, objects:, hashtags:)
      from_topics = Array(raw_topics).map { |row| normalize_text(row, max: 80) }.compact.map(&:downcase)
      from_hashtags = Array(hashtags).map { |tag| tag.to_s.delete_prefix("#").downcase }
      (from_topics + objects + from_hashtags).reject(&:blank?).uniq.first(40)
    end

    def normalize_faces
      people_rows = Array(@raw[:people] || @raw["people"]).filter_map do |row|
        next unless row.is_a?(Hash)
        role = (row[:role] || row["role"]).to_s
        next if role.blank?

        {
          person_id: row[:person_id] || row["person_id"],
          role: role,
          similarity: (row[:similarity] || row["similarity"]).to_f,
          label: (row[:label] || row["label"]).to_s.presence,
          age: (row[:age] || row["age"]).to_f.positive? ? (row[:age] || row["age"]).to_f.round(1) : nil,
          age_range: (row[:age_range] || row["age_range"]).to_s.presence,
          gender: (row[:gender] || row["gender"]).to_s.presence,
          gender_score: (row[:gender_score] || row["gender_score"]).to_f
        }.compact
      end

      total_count = (@raw[:face_count] || @raw["face_count"]).to_i
      total_count = [total_count, people_rows.size].max
      primary_user_count = people_rows.count { |row| row[:role].to_s == "primary_user" }
      secondary_person_count = people_rows.count { |row| row[:role].to_s == "secondary_person" }
      unknown_count = [total_count - (primary_user_count + secondary_person_count), 0].max

      {
        total_count: total_count,
        primary_user_count: primary_user_count,
        secondary_person_count: secondary_person_count,
        unknown_count: unknown_count,
        people: people_rows
      }
    end

    def build_identity_verification(faces:, topics:, detected_usernames:, source_profile_references:)
      profile_username = normalize_username(@profile&.username)
      people = faces.is_a?(Hash) ? Array(faces[:people]) : []
      person_ids = people.map { |row| row[:person_id] }.compact
      people_index = if @profile&.respond_to?(:instagram_story_people)
        @profile.instagram_story_people.where(id: person_ids).index_by(&:id)
      else
        {}
      end

      behavior_profile = @profile&.respond_to?(:instagram_profile_behavior_profile) ? @profile.instagram_profile_behavior_profile : nil
      behavior_summary = behavior_profile&.behavioral_summary
      behavior_summary = behavior_summary.is_a?(Hash) ? behavior_summary : {}
      face_identity_profile = behavior_summary["face_identity_profile"].is_a?(Hash) ? behavior_summary["face_identity_profile"] : {}
      historical_primary_person_id = face_identity_profile["person_id"] || face_identity_profile[:person_id]

      primary_person_present = people.any? { |row| row[:role].to_s == "primary_user" }
      recurring_primary_person = historical_primary_person_id.present? && people.any? { |row| row[:person_id].to_s == historical_primary_person_id.to_s }
      profile_topics = extract_profile_bio_topics
      topic_overlap = (profile_topics & Array(topics).map { |value| value.to_s.downcase.strip }.reject(&:blank?)).first(8)

      normalized_usernames = Array(detected_usernames).map { |value| normalize_username(value) }.reject(&:blank?)
      normalized_refs = Array(source_profile_references).map { |value| normalize_username(value) }.reject(&:blank?)
      profile_username_match = profile_username.present? && (normalized_usernames.include?(profile_username) || normalized_refs.include?(profile_username))
      external_reference_detected = (normalized_usernames + normalized_refs).uniq.any? { |value| value != profile_username }

      gender_consistency, observed_gender = face_gender_consistency(
        people: people,
        people_index: people_index,
        primary_person_id: historical_primary_person_id
      )
      age_consistency, observed_age_range = face_age_consistency(
        people: people,
        people_index: people_index,
        primary_person_id: historical_primary_person_id
      )

      confidence = 0.32
      confidence += 0.25 if primary_person_present
      confidence += 0.22 if recurring_primary_person
      confidence += 0.12 if profile_username_match
      confidence += 0.09 if topic_overlap.any?
      confidence += 0.06 if gender_consistency == "consistent"
      confidence += 0.06 if age_consistency == "consistent"
      confidence -= 0.18 if !primary_person_present && people.any?
      confidence -= 0.12 if external_reference_detected && !profile_username_match
      confidence = confidence.clamp(0.05, 0.98).round(2)

      owner_likelihood = if confidence >= 0.68
        "high"
      elsif confidence >= 0.45
        "medium"
      else
        "low"
      end

      reason_codes = []
      reason_codes << "primary_face_role_detected" if primary_person_present
      reason_codes << "historical_primary_person_match" if recurring_primary_person
      reason_codes << "profile_username_reference_detected" if profile_username_match
      reason_codes << "bio_topic_overlap_detected" if topic_overlap.any?
      reason_codes << "external_user_reference_detected" if external_reference_detected
      reason_codes << "gender_consistency_#{gender_consistency}" if gender_consistency != "unknown"
      reason_codes << "age_consistency_#{age_consistency}" if age_consistency != "unknown"

      {
        owner_likelihood: owner_likelihood,
        confidence: confidence,
        primary_person_present: primary_person_present,
        recurring_primary_person: recurring_primary_person,
        profile_username_match: profile_username_match,
        external_reference_detected: external_reference_detected,
        bio_topic_overlap: topic_overlap,
        observed_gender: observed_gender,
        observed_age_range: observed_age_range,
        gender_consistency: gender_consistency,
        age_consistency: age_consistency,
        reason_codes: reason_codes.uniq.first(12)
      }
    end

    def face_gender_consistency(people:, people_index:, primary_person_id:)
      observed = Array(people).map { |row| row[:gender].to_s.downcase.presence }.compact
      expected = nil
      if primary_person_id.present?
        person = people_index[primary_person_id]
        expected = person&.metadata&.dig("face_attributes", "primary_gender_cue").to_s.downcase.presence
      end

      return [ "unknown", observed.first ] if expected.blank? || observed.empty?
      return [ "consistent", observed.first ] if observed.include?(expected)

      [ "inconsistent", observed.first ]
    end

    def face_age_consistency(people:, people_index:, primary_person_id:)
      observed_ranges = Array(people).map { |row| row[:age_range].to_s.presence }.compact
      expected = nil
      if primary_person_id.present?
        person = people_index[primary_person_id]
        expected = person&.metadata&.dig("face_attributes", "primary_age_range").to_s.presence
      end

      return [ "unknown", observed_ranges.first ] if expected.blank? || observed_ranges.empty?
      return [ "consistent", observed_ranges.first ] if observed_ranges.include?(expected)

      [ "inconsistent", observed_ranges.first ]
    end

    def normalize_handle_array(values, prefix:)
      Array(values).map do |value|
        handle = normalize_text(value, max: 64)
        next if handle.blank?
        clean = handle.delete_prefix(prefix).downcase
        next if clean.blank?
        "#{prefix}#{clean}"
      end.compact.uniq
    end

    def detect_usernames(mentions:, profile_handles:, ocr_text:, transcript:, metadata:)
      rows = []
      rows.concat(Array(mentions).map { |value| value.to_s.delete_prefix("@") })
      rows.concat(Array(profile_handles))
      rows.concat(extract_source_profile_references(metadata: metadata))

      [ocr_text, transcript, metadata["caption"], metadata["story_ref"], metadata["story_url"], metadata["permalink"]].each do |text|
        next if text.to_s.blank?
        text.to_s.scan(OCR_USERNAME_REGEX).each do |match|
          rows << match.first.to_s
        end
        text.to_s.scan(BARE_USERNAME_REGEX).each do |match|
          token = match.first.to_s
          next unless username_like_token?(token)
          rows << token
        end
      end

      rows.map { |value| normalize_username(value) }.reject(&:blank?).uniq
    end

    def detect_reshare_indicators(ocr_text:, transcript:, metadata:)
      corpus = [ocr_text, transcript, metadata["caption"], metadata["story_url"], metadata["permalink"]]
        .map(&:to_s)
        .join("\n")
      return [] if corpus.blank?

      RESHARE_PATTERNS.filter_map do |pattern|
        match = corpus.match(pattern)
        match&.to_s&.downcase
      end.uniq
    end

    def third_party_profile_link_detected?(profile_username:, metadata:)
      return false if profile_username.blank?

      links = [metadata["story_url"], metadata["permalink"]].map(&:to_s).reject(&:blank?)
      return false if links.empty?

      links.any? do |link|
        next false unless link.include?("instagram.com/")
        normalized = link.downcase
        normalized.include?("/#{profile_username}/") ? false : normalized.match?(%r{instagram\.com/[a-z0-9._]+/?})
      end
    end

    def detect_meme_markers(ocr_text:, transcript:, metadata:)
      corpus = [ocr_text, transcript, metadata["caption"]].map(&:to_s).join("\n")
      markers = MEME_PATTERNS.filter_map do |pattern|
        match = corpus.match(pattern)
        match&.to_s&.downcase
      end
      text_lines = corpus.lines.map(&:strip).reject(&:blank?)
      if text_lines.length >= 2 && corpus.length >= 40
        markers << "multi_line_overlay_text"
      end
      markers.uniq
    end

    def infer_share_status(profile_username_detected:, external_usernames:, external_source_refs:, reshare_hits:, meme_markers:)
      return "owned" if profile_username_detected && external_usernames.empty? && external_source_refs.empty?
      return "reshared" if reshare_hits.any? || meme_markers.any?
      return "third_party" if external_usernames.any? || external_source_refs.any?

      "unknown"
    end

    def extract_source_profile_references(metadata:)
      refs = []
      story_ref = metadata["story_ref"].to_s
      refs << story_ref.delete_suffix(":") if story_ref.present?

      [metadata["story_url"], metadata["permalink"], metadata["media_url"]].each do |value|
        url = value.to_s
        next if url.blank?

        if (match = url.match(%r{instagram\.com/stories/([a-zA-Z0-9._]+)/?}i))
          refs << match[1]
        end
        if (match = url.match(%r{instagram\.com/([a-zA-Z0-9._]+)/?}i))
          segment = match[1].to_s.downcase
          refs << segment unless RESERVED_IG_SEGMENTS.include?(segment)
        end
      end

      refs
        .map { |value| normalize_username(value) }
        .reject(&:blank?)
        .select { |value| valid_instagram_username?(value) }
        .uniq
    end

    def extract_source_profile_ids(metadata:)
      candidates = []
      %w[source_profile_id owner_id profile_id user_id source_user_id].each do |key|
        value = metadata[key]
        candidates << value.to_s if value.to_s.match?(/\A\d+\z/)
      end

      story_id = metadata["story_id"].to_s
      story_id.scan(/(?<!\w)\d{5,}(?!\w)/).each { |token| candidates << token }

      candidates.map(&:to_s).reject(&:blank?).uniq.first(10)
    end

    def score_verified_signals(ocr_text:, transcript:, objects:, object_detections:, scenes:, hashtags:, mentions:, faces:)
      score = 0
      score += 2 if ocr_text.to_s.present?
      score += 2 if transcript.to_s.present?
      score += 2 if objects.any? || object_detections.any?
      score += 1 if scenes.any?
      score += 1 if hashtags.any? || mentions.any?
      score += 1 if faces[:primary_user_count].to_i.positive? || faces[:secondary_person_count].to_i.positive?
      score
    end

    def ownership_confidence(label:, reason_codes:, signal_score:)
      value = case label.to_s
      when "owned_by_profile" then 0.62
      when "insufficient_evidence" then 0.9
      when "meme_reshare" then 0.9
      when "reshare" then 0.86
      when "third_party_content" then 0.82
      when "unrelated_post" then 0.76
      else 0.6
      end
      value += 0.03 * reason_codes.size
      value += 0.02 if signal_score >= 4
      value.clamp(0.5, 0.98).round(2)
    end

    def ownership_summary(label:, external_usernames:, external_source_refs:, reshare_hits:, meme_markers:, primary_faces:, secondary_faces:, signal_score:)
      case label.to_s
      when "owned_by_profile"
        "Validated as likely profile-owned content (signal score #{signal_score})."
      when "insufficient_evidence"
        "Insufficient verified context (signal score #{signal_score}) to generate a grounded comment."
      when "meme_reshare"
        hints = (meme_markers.first(2) + reshare_hits.first(2)).uniq.join(", ")
        "Likely meme/reshared content#{hints.present? ? " (#{hints})" : ""}; excluded from comment generation."
      when "reshare"
        hints = reshare_hits.first(3).join(", ")
        "Likely reshare/credited content#{hints.present? ? " (#{hints})" : ""}; skipping full comment."
      when "third_party_content"
        usernames = external_usernames.first(3).join(", ")
        refs = external_source_refs.first(3).join(", ")
        parts = []
        parts << "account references #{usernames}" if usernames.present?
        parts << "source refs #{refs}" if refs.present?
        "Detected third-party content#{parts.any? ? " (#{parts.join('; ')})" : ""} with non-primary ownership signals."
      when "unrelated_post"
        "Detected non-primary face signals (primary=#{primary_faces}, secondary=#{secondary_faces}); post may be unrelated."
      else
        "Ownership could not be validated."
      end
    end

    def extract_profile_bio_topics
      bio = @profile&.respond_to?(:bio) ? @profile.bio.to_s.downcase : ""
      return [] if bio.blank?

      bio.scan(/[a-z0-9_]+/)
        .reject { |token| token.length < 3 }
        .uniq
        .first(30)
    end

    def normalize_text(value, max:)
      text = value.to_s.gsub(/\s+/, " ").strip
      return nil if text.blank?
      return text if text.length <= max

      text.byteslice(0, max)
    end

    def normalize_username(value)
      value.to_s.downcase.strip.delete_prefix("@")
    end

    def username_like_token?(token)
      value = token.to_s
      return false unless valid_instagram_username?(value)
      return false unless value.include?("_") || value.include?(".")

      true
    end

    def valid_instagram_username?(value)
      token = value.to_s.downcase.strip
      return false unless token.length.between?(3, 30)
      return false unless token.match?(/\A[a-z0-9._]+\z/)
      return false if token.include?("instagram.com")
      return false if token.start_with?("www.")
      return false if RESERVED_IG_SEGMENTS.include?(token)

      true
    end
  end
end
