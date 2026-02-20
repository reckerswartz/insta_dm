require "digest"

class InstagramProfileEvent < ApplicationRecord
  include InstagramProfileEvent::LocalStoryIntelligence
  include InstagramProfileEvent::Broadcastable
  include InstagramProfileEvent::CommentGenerationCoordinator

  belongs_to :instagram_profile

  has_one_attached :media
  has_one_attached :preview_image
  has_many :instagram_stories, foreign_key: :source_event_id, dependent: :nullify

  validates :kind, presence: true
  validates :external_id, presence: true
  validates :detected_at, presence: true

  # LLM Comment validations
  validates :llm_comment_provider, inclusion: { in: %w[ollama local], allow_nil: true }
  validates :llm_comment_status, inclusion: { in: %w[not_requested queued running completed failed skipped], allow_nil: true }
  validate :llm_comment_consistency, on: :update

  after_commit :broadcast_account_audit_logs_refresh
  after_commit :broadcast_story_archive_refresh, on: %i[create update]
  after_commit :append_profile_history_narrative, on: :create
  after_commit :broadcast_profile_events_refresh

  STORY_ARCHIVE_EVENT_KINDS = %w[
    story_downloaded
    story_image_downloaded_via_feed
    story_media_downloaded_via_feed
  ].freeze

  LLM_SUCCESS_STATUSES = %w[ok fallback_used error_fallback].freeze

  scope :recent_first, -> { order(detected_at: :desc, id: :desc) }









  def story_archive_item?
    STORY_ARCHIVE_EVENT_KINDS.include?(kind.to_s)
  end

  def capture_technical_details(context)
    profile = instagram_profile
    media_blob = media.attached? ? media.blob : nil
    timeline = story_timeline_data
    local_intelligence = context[:local_story_intelligence].is_a?(Hash) ? context[:local_story_intelligence] : {}
    verified_story_facts = context[:verified_story_facts].is_a?(Hash) ? context[:verified_story_facts] : {}
    story_ownership_classification = context[:story_ownership_classification].is_a?(Hash) ? context[:story_ownership_classification] : {}
    generation_policy = context[:generation_policy].is_a?(Hash) ? context[:generation_policy] : {}
    validated_story_insights = context[:validated_story_insights].is_a?(Hash) ? context[:validated_story_insights] : {}
    profile_preparation = context[:profile_preparation].is_a?(Hash) ? context[:profile_preparation] : {}
    verified_profile_history = Array(context[:verified_profile_history]).first(12)
    conversational_voice = context[:conversational_voice].is_a?(Hash) ? context[:conversational_voice] : {}

    {
      timestamp: Time.current.iso8601,
      event_id: id,
      story_id: metadata.is_a?(Hash) ? metadata["story_id"] : nil,
      timeline: timeline,
      media_info: media_blob ? {
        content_type: media_blob.content_type,
        size_bytes: media_blob.byte_size,
        dimensions: metadata.is_a?(Hash) ? metadata.slice("media_width", "media_height") : {},
        url: Rails.application.routes.url_helpers.rails_blob_path(media, only_path: true)
      } : {},
      local_story_intelligence: local_intelligence,
      analysis: {
        verified_story_facts: verified_story_facts,
        ownership_classification: story_ownership_classification,
        generation_policy: generation_policy,
        validated_story_insights: validated_story_insights,
        cv_ocr_evidence: context[:cv_ocr_evidence],
        historical_comparison: context[:historical_comparison],
        extraction_summary: {
          has_ocr_text: verified_story_facts[:ocr_text].to_s.present?,
          has_transcript: verified_story_facts[:transcript].to_s.present?,
          objects_count: Array(verified_story_facts[:objects]).size,
          object_detections_count: Array(verified_story_facts[:object_detections]).size,
          scenes_count: Array(verified_story_facts[:scenes]).size,
          hashtags_count: Array(verified_story_facts[:hashtags]).size,
          mentions_count: Array(verified_story_facts[:mentions]).size,
          detected_usernames_count: Array(verified_story_facts[:detected_usernames]).size,
          faces_count: verified_story_facts[:face_count].to_i,
          signal_score: verified_story_facts[:signal_score].to_i,
          source: verified_story_facts[:source].to_s,
          reason: verified_story_facts[:reason].to_s.presence
        }
      },
      profile_analysis: {
        username: profile&.username,
        display_name: profile&.display_name,
        bio: profile&.bio,
        bio_length: profile&.bio&.length || 0,
        detected_author_type: determine_author_type(profile),
        extracted_topics: extract_topics_from_profile(profile),
        profile_comment_preparation: profile_preparation,
        conversational_voice: conversational_voice,
        verified_profile_history: verified_profile_history
      },
      prompt_engineering: {
        final_prompt: context[:post_payload],
        image_description: context[:image_description],
        topics_used: context[:topics],
        author_classification: context[:author_type],
        historical_context: context[:historical_context],
        historical_story_context: Array(context[:historical_story_context]).first(10),
        historical_comparison: context[:historical_comparison],
        verified_story_facts: verified_story_facts,
        ownership_classification: story_ownership_classification,
        generation_policy: generation_policy,
        cv_ocr_evidence: context[:cv_ocr_evidence],
        profile_comment_preparation: profile_preparation,
        conversational_voice: conversational_voice,
        verified_profile_history: verified_profile_history,
        rules_applied: context[:post_payload]&.dig(:rules)
      }
    }
  end








  private


  def append_profile_history_narrative
    AppendProfileHistoryNarrativeJob.perform_later(
      instagram_profile_event_id: id,
      mode: "event"
    )
  rescue StandardError
    nil
  end
















  def resolve_people_from_faces(detected_faces:, fallback_image_bytes:, story_id:)
    account = instagram_profile&.instagram_account
    profile = instagram_profile
    return [] unless account && profile

    embedding_service = FaceEmbeddingService.new
    matcher = VectorMatchingService.new
    Array(detected_faces).first(5).filter_map do |face|
      candidate_image_bytes = face[:image_bytes].presence || fallback_image_bytes
      next if candidate_image_bytes.blank?
      observation_signature = event_face_observation_signature(story_id: story_id, face: face)

      vector_payload = embedding_service.embed(
        media_payload: { story_id: story_id.to_s, media_type: "image", image_bytes: candidate_image_bytes },
        face: face
      )
      vector = Array(vector_payload[:vector]).map(&:to_f)
      next if vector.empty?

      match = matcher.match_or_create!(
        account: account,
        profile: profile,
        embedding: vector,
        occurred_at: occurred_at || detected_at || Time.current,
        observation_signature: observation_signature
      )
      person = match[:person]
      update_person_face_attributes_for_event!(person: person, face: face)
      {
        person_id: person.id,
        role: match[:role].to_s,
        label: person.label.to_s.presence,
        similarity: match[:similarity],
        age: face[:age],
        age_range: face[:age_range],
        gender: face[:gender],
        gender_score: face[:gender_score].to_f
      }.compact
    end
  rescue StandardError
    []
  end

  def event_face_observation_signature(story_id:, face:)
    bbox = face[:bounding_box].is_a?(Hash) ? face[:bounding_box] : {}
    [
      "event",
      id,
      story_id.to_s,
      face[:frame_index].to_i,
      face[:timestamp_seconds].to_f.round(3),
      bbox["x1"],
      bbox["y1"],
      bbox["x2"],
      bbox["y2"]
    ].map(&:to_s).join(":")
  end

  def update_person_face_attributes_for_event!(person:, face:)
    return unless person

    metadata = person.metadata.is_a?(Hash) ? person.metadata.deep_dup : {}
    attrs = metadata["face_attributes"].is_a?(Hash) ? metadata["face_attributes"].deep_dup : {}

    gender = face[:gender].to_s.strip.downcase
    if gender.present?
      gender_counts = attrs["gender_counts"].is_a?(Hash) ? attrs["gender_counts"].deep_dup : {}
      gender_counts[gender] = gender_counts[gender].to_i + 1
      attrs["gender_counts"] = gender_counts
      attrs["primary_gender_cue"] = gender_counts.max_by { |_key, count| count.to_i }&.first
    end

    age_range = face[:age_range].to_s.strip
    if age_range.present?
      age_counts = attrs["age_range_counts"].is_a?(Hash) ? attrs["age_range_counts"].deep_dup : {}
      age_counts[age_range] = age_counts[age_range].to_i + 1
      attrs["age_range_counts"] = age_counts
      attrs["primary_age_range"] = age_counts.max_by { |_key, count| count.to_i }&.first
    end

    age_value = face[:age].to_f
    if age_value.positive?
      samples = Array(attrs["age_samples"]).map(&:to_f).first(19)
      samples << age_value.round(1)
      attrs["age_samples"] = samples
      attrs["age_estimate"] = (samples.sum / samples.length.to_f).round(1)
    end

    attrs["last_observed_at"] = Time.current.iso8601
    metadata["face_attributes"] = attrs
    person.update_columns(metadata: metadata, updated_at: Time.current)
  rescue StandardError
    nil
  end

  def recent_story_intelligence_context(profile)
    return [] unless profile

    profile.instagram_profile_events
      .where(kind: STORY_ARCHIVE_EVENT_KINDS)
      .order(detected_at: :desc, id: :desc)
      .limit(18)
      .map do |event|
        meta = event.metadata.is_a?(Hash) ? event.metadata : {}
        intel = meta["local_story_intelligence"].is_a?(Hash) ? meta["local_story_intelligence"] : {}
        objects = merge_unique_values(intel["objects"], meta["content_signals"]).first(8)
        hashtags = merge_unique_values(intel["hashtags"], meta["hashtags"]).first(8)
        mentions = merge_unique_values(intel["mentions"], meta["mentions"]).first(6)
        profile_handles = merge_unique_values(intel["profile_handles"], meta["profile_handles"]).first(8)
        topics = merge_unique_values(intel["topics"], meta["topics"]).first(8)
        ocr_text = first_present(intel["ocr_text"], meta["ocr_text"])
        transcript = first_present(intel["transcript"], meta["transcript"])
        scenes = normalize_hash_array(intel["scenes"], meta["scenes"]).first(20)
        people = Array(intel["people"] || meta["face_people"]).first(10)
        face_count = (intel["face_count"] || meta["face_count"]).to_i
        next if objects.empty? && hashtags.empty? && mentions.empty? && profile_handles.empty? && topics.empty? && scenes.empty? && ocr_text.blank? && transcript.blank? && face_count <= 0

        {
          event_id: event.id,
          occurred_at: event.occurred_at&.iso8601 || event.detected_at&.iso8601,
          topics: topics,
          objects: objects,
          scenes: scenes,
          hashtags: hashtags,
          mentions: mentions,
          profile_handles: profile_handles,
          ocr_text: ocr_text.to_s.byteslice(0, 220),
          transcript: transcript.to_s.byteslice(0, 220),
          face_count: face_count,
          scenes_count: scenes.length,
          people: people
        }
      end.compact
  rescue StandardError
    []
  end

  def format_story_intelligence_context(rows)
    entries = Array(rows).first(10)
    return "" if entries.empty?

    lines = entries.map do |row|
      parts = []
      parts << "topics=#{Array(row[:topics]).join(',')}" if Array(row[:topics]).any?
      parts << "objects=#{Array(row[:objects]).join(',')}" if Array(row[:objects]).any?
      parts << "hashtags=#{Array(row[:hashtags]).join(',')}" if Array(row[:hashtags]).any?
      parts << "mentions=#{Array(row[:mentions]).join(',')}" if Array(row[:mentions]).any?
      parts << "handles=#{Array(row[:profile_handles]).join(',')}" if Array(row[:profile_handles]).any?
      parts << "faces=#{row[:face_count].to_i}" if row[:face_count].to_i.positive?
      parts << "scenes=#{row[:scenes_count].to_i}" if row[:scenes_count].to_i.positive?
      parts << "ocr=#{row[:ocr_text]}" if row[:ocr_text].to_s.present?
      parts << "transcript=#{row[:transcript]}" if row[:transcript].to_s.present?
      "- #{parts.join(' | ')}"
    end

    "Recent structured story intelligence:\n#{lines.join("\n")}"
  end

  def build_compact_historical_context(profile:, historical_story_context:, verified_profile_history:, profile_preparation:)
    summary = []
    if profile
      summary << profile.history_narrative_text(max_chunks: 2).to_s
    end
    structured = format_story_intelligence_context(historical_story_context)
    summary << structured.to_s
    summary << format_verified_profile_history(verified_profile_history)
    summary << format_profile_preparation(profile_preparation)

    compact = summary
      .map(&:to_s)
      .map(&:strip)
      .reject(&:blank?)
      .join("\n")

    compact.byteslice(0, 650)
  end

  def latest_profile_comment_preparation(profile)
    meta = profile&.instagram_profile_behavior_profile&.metadata
    payload = meta.is_a?(Hash) ? meta["comment_generation_preparation"] : nil
    payload.is_a?(Hash) ? payload.deep_symbolize_keys : {}
  rescue StandardError
    {}
  end

  def recent_analyzed_profile_history(profile)
    return [] unless profile

    profile.instagram_profile_posts
      .recent_first
      .limit(12)
      .map do |post|
        analysis = post.analysis.is_a?(Hash) ? post.analysis : {}
        faces = post.instagram_post_faces
        next if analysis.blank? && !faces.exists?

        {
          post_id: post.id,
          shortcode: post.shortcode,
          taken_at: post.taken_at&.iso8601,
          caption: post.caption.to_s.byteslice(0, 220),
          image_description: analysis["image_description"].to_s.byteslice(0, 220),
          topics: Array(analysis["topics"]).map(&:to_s).reject(&:blank?).uniq.first(8),
          objects: Array(analysis["objects"]).map(&:to_s).reject(&:blank?).uniq.first(8),
          hashtags: Array(analysis["hashtags"]).map(&:to_s).reject(&:blank?).uniq.first(8),
          mentions: Array(analysis["mentions"]).map(&:to_s).reject(&:blank?).uniq.first(8),
          face_count: faces.count,
          primary_face_count: faces.where(role: "primary_user").count,
          secondary_face_count: faces.where(role: "secondary_person").count
        }
      end.compact
  rescue StandardError
    []
  end

  def build_conversational_voice_profile(profile:, historical_story_context:, verified_profile_history:, profile_preparation:)
    behavior_summary = profile&.instagram_profile_behavior_profile&.behavioral_summary
    behavior_summary = {} unless behavior_summary.is_a?(Hash)
    preparation = profile_preparation.is_a?(Hash) ? profile_preparation : {}
    recent_comments = recent_llm_comments_for_profile(profile).first(6)
    recent_topics = Array(verified_profile_history).flat_map { |row| Array(row[:topics]) }.map(&:to_s).reject(&:blank?).uniq.first(10)
    recurring_story_topics = Array(historical_story_context).flat_map { |row| Array(row[:topics]) }.map(&:to_s).reject(&:blank?).uniq.first(10)

    {
      author_type: determine_author_type(profile),
      profile_tags: profile ? profile.profile_tags.pluck(:name).sort.first(10) : [],
      bio_keywords: extract_topics_from_profile(profile).first(10),
      recurring_topics: (recent_topics + recurring_story_topics + Array(behavior_summary["topic_clusters"]).map(&:first)).map(&:to_s).reject(&:blank?).uniq.first(12),
      recurring_hashtags: Array(behavior_summary["top_hashtags"]).map(&:first).map(&:to_s).reject(&:blank?).first(10),
      frequent_people_labels: Array(behavior_summary["frequent_secondary_persons"]).map { |row| row.is_a?(Hash) ? row["label"] || row[:label] : nil }.map(&:to_s).reject(&:blank?).uniq.first(8),
      prior_comment_examples: recent_comments.map { |value| value.to_s.byteslice(0, 120) },
      identity_consistency: preparation[:identity_consistency].is_a?(Hash) ? preparation[:identity_consistency] : preparation["identity_consistency"],
      profile_preparation_reason: preparation[:reason].to_s.presence || preparation["reason"].to_s.presence
    }.compact
  rescue StandardError
    {}
  end

  def format_verified_profile_history(rows)
    entries = Array(rows).first(8)
    return "" if entries.empty?

    lines = entries.map do |row|
      parts = []
      parts << "shortcode=#{row[:shortcode]}" if row[:shortcode].to_s.present?
      parts << "topics=#{Array(row[:topics]).join(',')}" if Array(row[:topics]).any?
      parts << "objects=#{Array(row[:objects]).join(',')}" if Array(row[:objects]).any?
      parts << "hashtags=#{Array(row[:hashtags]).join(',')}" if Array(row[:hashtags]).any?
      parts << "mentions=#{Array(row[:mentions]).join(',')}" if Array(row[:mentions]).any?
      parts << "faces=#{row[:face_count].to_i}" if row[:face_count].to_i.positive?
      parts << "primary_faces=#{row[:primary_face_count].to_i}" if row[:primary_face_count].to_i.positive?
      parts << "secondary_faces=#{row[:secondary_face_count].to_i}" if row[:secondary_face_count].to_i.positive?
      parts << "desc=#{row[:image_description]}" if row[:image_description].to_s.present?
      "- #{parts.join(' | ')}"
    end

    "Recent analyzed profile posts:\n#{lines.join("\n")}"
  end

  def format_profile_preparation(payload)
    data = payload.is_a?(Hash) ? payload : {}
    return "" if data.blank?

    identity = data[:identity_consistency].is_a?(Hash) ? data[:identity_consistency] : data["identity_consistency"]
    analysis = data[:analysis].is_a?(Hash) ? data[:analysis] : data["analysis"]

    parts = []
    parts << "ready=#{ActiveModel::Type::Boolean.new.cast(data[:ready_for_comment_generation] || data["ready_for_comment_generation"])}"
    parts << "reason=#{data[:reason_code] || data["reason_code"]}"
    parts << "analyzed_posts=#{analysis[:analyzed_posts_count] || analysis["analyzed_posts_count"]}" if analysis.is_a?(Hash)
    parts << "structured_posts=#{analysis[:posts_with_structured_signals_count] || analysis["posts_with_structured_signals_count"]}" if analysis.is_a?(Hash)
    if identity.is_a?(Hash)
      parts << "identity_consistent=#{ActiveModel::Type::Boolean.new.cast(identity[:consistent] || identity["consistent"])}"
      parts << "identity_ratio=#{identity[:dominance_ratio] || identity["dominance_ratio"]}"
      parts << "identity_reason=#{identity[:reason_code] || identity["reason_code"]}"
    end
    return "" if parts.empty?

    "Profile preparation: #{parts.join(' | ')}"
  end

  def story_timeline_data
    raw = metadata.is_a?(Hash) ? metadata : {}
    story = instagram_stories.order(taken_at: :desc, id: :desc).first
    posted_at = raw["upload_time"].presence || raw["taken_at"].presence || story&.taken_at&.iso8601
    downloaded_at = raw["downloaded_at"].presence || occurred_at&.iso8601 || created_at&.iso8601

    {
      story_posted_at: posted_at,
      downloaded_to_system_at: downloaded_at,
      event_detected_at: detected_at&.iso8601
    }
  end

  def estimated_generation_seconds(queue_state:)
    base = 18
    queue_size =
      begin
        require "sidekiq/api"
        Sidekiq::Queue.new("ai").size.to_i
      rescue StandardError
        0
      end
    queue_factor = queue_state ? queue_size * 4 : [queue_size - 1, 0].max * 3
    attempt_factor = llm_comment_attempts.to_i * 6
    preprocess_factor = local_context_preprocess_penalty
    (base + queue_factor + attempt_factor + preprocess_factor).clamp(10, 240)
  end

  def local_context_preprocess_penalty
    raw = metadata.is_a?(Hash) ? metadata : {}
    has_context = raw["local_story_intelligence"].is_a?(Hash) ||
      raw["ocr_text"].to_s.present? ||
      Array(raw["content_signals"]).any?
    return 0 if has_context

    media_type = media&.blob&.content_type.to_s.presence || raw["media_content_type"].to_s
    media_type.start_with?("image/") ? 16 : 8
  rescue StandardError
    0
  end

  def recent_llm_comments_for_profile(profile)
    return [] unless profile

    profile.instagram_profile_events
      .where.not(id: id)
      .where.not(llm_generated_comment: [nil, ""])
      .order(llm_comment_generated_at: :desc, id: :desc)
      .limit(12)
      .pluck(:llm_generated_comment)
      .map(&:to_s)
      .reject(&:blank?)
  rescue StandardError
    []
  end

  def build_cv_ocr_evidence(local_story_intelligence:)
    payload = local_story_intelligence.is_a?(Hash) ? local_story_intelligence : {}
    {
      source: payload[:source].to_s,
      reason: payload[:reason].to_s.presence,
      ocr_text: payload[:ocr_text].to_s,
      transcript: payload[:transcript].to_s,
      objects: Array(payload[:objects]).first(20),
      scenes: Array(payload[:scenes]).first(20),
      hashtags: Array(payload[:hashtags]).first(20),
      mentions: Array(payload[:mentions]).first(20),
      profile_handles: Array(payload[:profile_handles]).first(20),
      source_account_reference: payload[:source_account_reference].to_s,
      source_profile_ids: Array(payload[:source_profile_ids]).first(10),
      media_type: payload[:media_type].to_s,
      face_count: payload[:face_count].to_i,
      people: Array(payload[:people]).first(10),
      object_detections: normalize_hash_array(payload[:object_detections]).first(30),
      ocr_blocks: normalize_hash_array(payload[:ocr_blocks]).first(30)
    }
  end

  def build_historical_comparison(current:, historical_story_context:)
    current_hash = current.is_a?(Hash) ? current : {}
    current_topics = Array(current_hash[:topics]).map(&:to_s).reject(&:blank?).uniq
    current_objects = Array(current_hash[:objects]).map(&:to_s).reject(&:blank?).uniq
    current_scenes = Array(current_hash[:scenes]).map { |row| row.is_a?(Hash) ? row[:type] || row["type"] : row }.map(&:to_s).reject(&:blank?).uniq
    current_hashtags = Array(current_hash[:hashtags]).map(&:to_s).reject(&:blank?).uniq
    current_mentions = Array(current_hash[:mentions]).map(&:to_s).reject(&:blank?).uniq
    current_profile_handles = Array(current_hash[:profile_handles]).map(&:to_s).reject(&:blank?).uniq
    current_people = Array(current_hash[:people]).map { |row| row.is_a?(Hash) ? row[:person_id] || row["person_id"] : nil }.compact.map(&:to_s)

    historical_rows = Array(historical_story_context)
    hist_topics = historical_rows.flat_map { |row| Array(row[:topics] || row["topics"]) }.map(&:to_s).reject(&:blank?).uniq
    hist_objects = historical_rows.flat_map { |row| Array(row[:objects] || row["objects"]) }.map(&:to_s).reject(&:blank?).uniq
    hist_scenes = historical_rows.flat_map { |row| Array(row[:scenes] || row["scenes"]) }
      .map { |row| row.is_a?(Hash) ? row[:type] || row["type"] : row }
      .map(&:to_s)
      .reject(&:blank?)
      .uniq
    hist_hashtags = historical_rows.flat_map { |row| Array(row[:hashtags] || row["hashtags"]) }.map(&:to_s).reject(&:blank?).uniq
    hist_mentions = historical_rows.flat_map { |row| Array(row[:mentions] || row["mentions"]) }.map(&:to_s).reject(&:blank?).uniq
    hist_profile_handles = historical_rows.flat_map { |row| Array(row[:profile_handles] || row["profile_handles"]) }.map(&:to_s).reject(&:blank?).uniq
    hist_people = historical_rows.flat_map { |row| Array(row[:people] || row["people"]) }
      .map { |row| row.is_a?(Hash) ? row[:person_id] || row["person_id"] : nil }
      .compact
      .map(&:to_s)
      .uniq

    {
      shared_topics: (current_topics & hist_topics).first(12),
      novel_topics: (current_topics - hist_topics).first(12),
      shared_objects: (current_objects & hist_objects).first(12),
      novel_objects: (current_objects - hist_objects).first(12),
      shared_scenes: (current_scenes & hist_scenes).first(12),
      novel_scenes: (current_scenes - hist_scenes).first(12),
      recurring_hashtags: (current_hashtags & hist_hashtags).first(12),
      recurring_mentions: (current_mentions & hist_mentions).first(12),
      recurring_profile_handles: (current_profile_handles & hist_profile_handles).first(12),
      recurring_people_ids: (current_people & hist_people).first(12),
      has_historical_overlap: ((current_topics & hist_topics).any? || (current_objects & hist_objects).any? || (current_scenes & hist_scenes).any? || (current_hashtags & hist_hashtags).any? || (current_profile_handles & hist_profile_handles).any?)
    }
  end

  def normalize_hash_array(*values)
    values.flat_map { |value| Array(value) }.select { |row| row.is_a?(Hash) }
  end

  def normalize_people_rows(*values)
    rows = values.flat_map { |value| Array(value) }

    rows.filter_map do |row|
      next unless row.is_a?(Hash)

      {
        person_id: row[:person_id] || row["person_id"],
        role: (row[:role] || row["role"]).to_s.presence,
        label: (row[:label] || row["label"]).to_s.presence,
        similarity: (row[:similarity] || row["similarity"] || row[:match_similarity] || row["match_similarity"]).to_f,
        relationship: (row[:relationship] || row["relationship"]).to_s.presence,
        appearances: (row[:appearances] || row["appearances"]).to_i,
        linked_usernames: Array(row[:linked_usernames] || row["linked_usernames"]).map(&:to_s).reject(&:blank?).first(8),
        age: (row[:age] || row["age"]).to_f.positive? ? (row[:age] || row["age"]).to_f.round(1) : nil,
        age_range: (row[:age_range] || row["age_range"]).to_s.presence,
        gender: (row[:gender] || row["gender"]).to_s.presence,
        gender_score: (row[:gender_score] || row["gender_score"]).to_f
      }.compact
    end.uniq { |row| [ row[:person_id], row[:role], row[:similarity].to_f.round(3), row[:label] ] }
  end

  def normalize_object_detections(*values, limit: 120)
    rows = normalize_hash_array(*values).map do |row|
      label = (row[:label] || row["label"] || row[:description] || row["description"]).to_s.downcase.strip
      next if label.blank?

      {
        label: label,
        confidence: (row[:confidence] || row["confidence"] || row[:score] || row["score"] || row[:max_confidence] || row["max_confidence"]).to_f,
        bbox: row[:bbox].is_a?(Hash) ? row[:bbox] : (row["bbox"].is_a?(Hash) ? row["bbox"] : {}),
        timestamps: Array(row[:timestamps] || row["timestamps"]).map(&:to_f).first(80)
      }
    end.compact

    rows
      .uniq { |row| [ row[:label], row[:bbox], row[:timestamps].first(6) ] }
      .sort_by { |row| -row[:confidence].to_f }
      .first(limit.to_i.clamp(1, 300))
  end

  def story_excluded_from_narrative?(ownership:, policy:)
    ownership_hash = ownership.is_a?(Hash) ? ownership : {}
    policy_hash = policy.is_a?(Hash) ? policy : {}
    label = (ownership_hash[:label] || ownership_hash["label"]).to_s
    return true if %w[reshare third_party_content unrelated_post meme_reshare].include?(label)

    allow_comment_value = if policy_hash.key?(:allow_comment)
      policy_hash[:allow_comment]
    else
      policy_hash["allow_comment"]
    end
    allow_comment = ActiveModel::Type::Boolean.new.cast(allow_comment_value)
    reason_code = (policy_hash[:reason_code] || policy_hash["reason_code"]).to_s
    !allow_comment && reason_code.match?(/(reshare|third_party|unrelated|meme)/)
  end

  def extract_source_account_reference(raw:, story_meta:)
    value = raw["story_ref"].to_s.presence || story_meta["story_ref"].to_s.presence
    value = value.delete_suffix(":") if value.to_s.present?
    return value if value.to_s.present?

    url = raw["story_url"].to_s.presence || raw["permalink"].to_s.presence || story_meta["story_url"].to_s.presence
    return nil if url.blank?

    match = url.match(%r{instagram\.com/stories/([a-zA-Z0-9._]+)/?}i) || url.match(%r{instagram\.com/([a-zA-Z0-9._]+)/?}i)
    match ? match[1].to_s.downcase : nil
  end

  def extract_source_profile_ids_from_metadata(raw:, story_meta:)
    rows = []
    %w[source_profile_id owner_id profile_id user_id source_user_id].each do |key|
      value = raw[key] || story_meta[key]
      rows << value.to_s if value.to_s.match?(/\A\d+\z/)
    end
    story_id = raw["story_id"].to_s.presence || story_meta["story_id"].to_s
    story_id.to_s.scan(/(?<!\w)\d{5,}(?!\w)/).each { |token| rows << token }
    rows.uniq.first(10)
  end

  def determine_author_type(profile)
    return "unknown" unless profile

    bio = profile.bio.to_s.downcase

    if bio.include?("creator") || bio.include?("artist")
      "creator"
    elsif bio.include?("business") || bio.include?("entrepreneur")
      "business"
    else
      "personal"
    end
  end

  def extract_topics_from_profile(profile)
    return [] unless profile&.bio

    topics = []
    bio = profile.bio.downcase

    topic_keywords = {
      "fitness" => %w[fitness gym workout health],
      "food" => %w[food cooking chef recipe],
      "travel" => %w[travel wanderlust adventure],
      "fashion" => %w[fashion style outfit beauty],
      "tech" => %w[tech technology coding software],
      "art" => %w[art artist creative design],
      "business" => %w[business entrepreneur startup],
      "photography" => %w[photography photo camera]
    }

    topic_keywords.each do |topic, keywords|
      topics << topic if keywords.any? { |keyword| bio.include?(keyword) }
    end

    topics.uniq
  end
end
