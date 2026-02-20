# frozen_string_literal: true

module StoryIntelligence
  # Service for building story intelligence payloads
  # Extracted from InstagramProfileEvent::LocalStoryIntelligence to follow Single Responsibility Principle
  class PayloadBuilder
    include ActiveModel::Validations

    def initialize(event:)
      @event = event
    end

    def build_payload
      raw = event_metadata
      story = event_story
      story_meta = story_metadata(story)
      
      embedded = extract_embedded_intelligence(raw, story_meta)
      
      payload = build_base_payload(embedded, raw, story_meta)
      enrich_with_live_intelligence(payload) if needs_enrichment?(payload)
      handle_blank_payload(payload) if payload_blank?(payload)

      payload
    rescue StandardError
      build_error_payload
    end

    private

    attr_reader :event

    def event_metadata
      event.metadata.is_a?(Hash) ? event.metadata : {}
    end

    def event_story
      event.instagram_stories.order(updated_at: :desc, id: :desc).first
    end

    def story_metadata(story)
      story&.metadata.is_a?(Hash) ? story.metadata : {}
    end

    def extract_embedded_intelligence(raw, story_meta)
      story_embedded = story_meta["content_understanding"].is_a?(Hash) ? story_meta["content_understanding"] : {}
      event_embedded = raw["local_story_intelligence"].is_a?(Hash) ? raw["local_story_intelligence"] : {}
      
      story_embedded.presence || event_embedded.presence || {}
    end

    def build_base_payload(embedded, raw, story_meta)
      ocr_text = extract_first_present(embedded, raw, story_meta, "ocr_text")
      transcript = extract_first_present(embedded, raw, story_meta, "transcript")
      
      objects = merge_unique_values(
        embedded["objects"],
        raw["content_signals"],
        story_meta["content_signals"]
      )
      
      hashtags = merge_unique_values(
        embedded["hashtags"],
        raw["hashtags"],
        story_meta["hashtags"]
      )
      
      mentions = merge_unique_values(
        embedded["mentions"],
        raw["mentions"],
        story_meta["mentions"]
      )
      
      profile_handles = merge_unique_values(
        embedded["profile_handles"],
        raw["profile_handles"],
        story_meta["profile_handles"]
      )

      extract_hashtags_and_mentions_from_ocr!(hashtags, mentions, profile_handles, ocr_text)
      
      object_detections = normalize_object_detections(
        embedded["object_detections"],
        raw["object_detections"],
        story_meta["object_detections"]
      )
      
      objects = merge_unique_values(objects, extract_object_labels(object_detections))
      
      topics = merge_unique_values(
        embedded["topics"],
        objects,
        hashtags.map { |tag| tag.to_s.delete_prefix("#") }
      )

      {
        ocr_text: ocr_text.to_s.presence,
        transcript: transcript.to_s.presence,
        objects: objects,
        hashtags: hashtags,
        mentions: mentions,
        profile_handles: profile_handles,
        topics: topics,
        scenes: normalize_hash_array(embedded["scenes"], raw["scenes"], story_meta["scenes"]).first(80),
        ocr_blocks: normalize_hash_array(embedded["ocr_blocks"], raw["ocr_blocks"], story_meta["ocr_blocks"]).first(120),
        object_detections: object_detections,
        face_count: calculate_face_count(embedded, raw),
        people: normalize_people_rows(embedded["people"], raw["face_people"], raw["people"]).first(12),
        source_account_reference: extract_source_account_reference(raw, story_meta),
        source_profile_ids: extract_source_profile_ids_from_metadata(raw, story_meta),
        media_type: extract_media_type(raw, story_meta),
        source: determine_source(embedded, event_embedded_present?(raw))
      }
    end

    def extract_first_present(embedded, raw, story_meta, field)
      first_present(
        embedded[field],
        raw["local_story_intelligence"]&.dig(field),
        story_meta[field],
        raw[field]
      )
    end

    def extract_hashtags_and_mentions_from_ocr!(hashtags, mentions, profile_handles, ocr_text)
      return unless ocr_text.to_s.present?

      hashtags.concat(ocr_text.scan(/#[a-zA-Z0-9_]+/).map(&:downcase).uniq.first(20)) if hashtags.empty?
      mentions.concat(ocr_text.scan(/@[a-zA-Z0-9._]+/).map(&:downcase).uniq.first(20)) if mentions.empty?
      
      if profile_handles.empty?
        extracted_handles = ocr_text.scan(/\b[a-zA-Z0-9._]{3,30}\b/)
          .map(&:downcase)
          .select { |token| token.include?("_") || token.include?(".") }
          .reject { |token| token.include?("instagram.com") }
          .uniq
          .first(30)
        profile_handles.concat(extracted_handles)
      end
    end

    def extract_object_labels(object_detections)
      object_detections
        .map { |row| row.is_a?(Hash) ? (row[:label] || row["label"] || row[:description] || row["description"]) : nil }
        .map(&:to_s)
        .map(&:strip)
        .reject(&:blank?)
    end

    def calculate_face_count(embedded, raw)
      event_embedded = raw["local_story_intelligence"].is_a?(Hash) ? raw["local_story_intelligence"] : {}
      normalized_people = normalize_people_rows(event_embedded["people"], raw["face_people"], raw["people"])
      
      [
        (event_embedded["face_count"] || embedded["faces_count"] || raw["face_count"]).to_i,
        normalized_people.size
      ].max
    end

    def extract_media_type(raw, story_meta)
      raw["media_type"].to_s.presence ||
        story_meta["media_type"].to_s.presence ||
        event.media&.blob&.content_type.to_s.presence
    end

    def determine_source(embedded, event_embedded_present)
      if embedded.present?
        "story_processing"
      elsif event_embedded_present
        "event_local_pipeline"
      else
        "event_metadata"
      end
    end

    def event_embedded_present?(raw)
      raw["local_story_intelligence"].is_a?(Hash) && raw["local_story_intelligence"].present?
    end

    def needs_enrichment?(payload)
      event.media.attached? &&
        Array(payload[:object_detections]).empty? &&
        Array(payload[:ocr_blocks]).empty? &&
        Array(payload[:scenes]).empty?
    end

    def enrich_with_live_intelligence(payload)
      story_id = event_metadata["story_id"].to_s.presence || event.id.to_s
      extracted = extract_live_intelligence(story_id)
      
      return unless extracted.is_a?(Hash)

      merge_extracted_intelligence(payload, extracted)
      update_source_if_enriched(payload, extracted)
    end

    def merge_extracted_intelligence(payload, extracted)
      payload[:scenes] = normalize_hash_array(payload[:scenes], extracted[:scenes]).first(80)
      payload[:ocr_blocks] = normalize_hash_array(payload[:ocr_blocks], extracted[:ocr_blocks]).first(120)
      payload[:object_detections] = normalize_object_detections(payload[:object_detections], extracted[:object_detections], limit: 120)
    end

    def update_source_if_enriched(payload, extracted)
      if enriched?(extracted)
        payload[:source] = "live_local_enrichment"
      end
    end

    def enriched?(extracted)
      extracted[:scenes].any? || extracted[:ocr_blocks].any? || extracted[:object_detections].any?
    end

    def payload_blank?(payload)
      payload[:ocr_text].to_s.strip.blank? &&
        payload[:transcript].to_s.strip.blank? &&
        Array(payload[:objects]).empty? &&
        Array(payload[:object_detections]).empty? &&
        Array(payload[:ocr_blocks]).empty? &&
        Array(payload[:scenes]).empty? &&
        Array(payload[:hashtags]).empty? &&
        Array(payload[:mentions]).empty? &&
        Array(payload[:profile_handles]).empty? &&
        Array(payload[:topics]).empty? &&
        payload[:face_count].to_i <= 0 &&
        Array(payload[:people]).empty?
    end

    def handle_blank_payload(payload)
      return unless event.media.attached?

      story_id = event_metadata["story_id"].to_s.presence || event.id.to_s
      extracted = extract_live_intelligence(story_id)
      
      if extracted.is_a?(Hash)
        if !payload_blank?(extracted)
          payload.replace(extracted)
        elsif extracted[:reason].to_s.present?
          payload[:reason] = extracted[:reason].to_s
        end
      end

      if payload_blank?(payload)
        payload[:source] = "unavailable"
        payload[:reason] = payload[:reason].to_s.presence || "local_ai_extraction_empty"
      end
    end

    def extract_live_intelligence(story_id)
      content_type = event.media&.blob&.content_type.to_s
      return {} if content_type.blank?

      if content_type.start_with?("image/")
        extract_image_intelligence(story_id)
      elsif content_type.start_with?("video/")
        extract_video_intelligence(story_id, content_type)
      else
        {}
      end
    rescue StandardError
      {}
    end

    def extract_image_intelligence(story_id)
      image_bytes = event.media.download
      detection = FaceDetectionService.new.detect(
        media_payload: { story_id: story_id.to_s, image_bytes: image_bytes }
      )
      understanding = StoryContentUnderstandingService.new.build(
        media_type: "image",
        detections: [detection],
        transcript_text: nil
      )
      people = event.send(:resolve_people_from_faces, detected_faces: Array(detection[:faces]), fallback_image_bytes: image_bytes, story_id: story_id)

      {
        ocr_text: understanding[:ocr_text].to_s.presence,
        transcript: understanding[:transcript].to_s.presence,
        objects: Array(understanding[:objects]).map(&:to_s).reject(&:blank?).uniq.first(30),
        hashtags: Array(understanding[:hashtags]).map(&:to_s).reject(&:blank?).uniq.first(20),
        mentions: Array(understanding[:mentions]).map(&:to_s).reject(&:blank?).uniq.first(20),
        profile_handles: Array(understanding[:profile_handles]).map(&:to_s).reject(&:blank?).uniq.first(30),
        topics: Array(understanding[:topics]).map(&:to_s).reject(&:blank?).uniq.first(30),
        scenes: Array(understanding[:scenes]).first(80),
        ocr_blocks: Array(understanding[:ocr_blocks]).first(120),
        object_detections: event.send(:normalize_object_detections, understanding[:object_detections], limit: 120),
        face_count: Array(detection[:faces]).length,
        people: people,
        reason: detection.dig(:metadata, :reason).to_s.presence,
        source: "live_local_vision_ocr"
      }
    end

    def extract_video_intelligence(story_id, content_type)
      video_bytes = event.media.download
      # Implementation would follow the video extraction logic
      # This is simplified for the refactoring example
      {}
    end

    def build_error_payload
      {
        ocr_text: nil,
        transcript: nil,
        objects: [],
        hashtags: [],
        mentions: [],
        profile_handles: [],
        topics: [],
        scenes: [],
        ocr_blocks: [],
        object_detections: [],
        source: "unavailable"
      }
    end

    # Helper methods (these would be extracted to a utility module)
    def first_present(*values)
      values.each do |value|
        text = value.to_s.strip
        return text if text.present?
      end
      nil
    end

    def merge_unique_values(*values)
      values.flat_map { |value| Array(value) }
        .map(&:to_s)
        .map(&:strip)
        .reject(&:blank?)
        .uniq
        .first(40)
    end

    def normalize_hash_array(*values)
      values.flat_map { |value| Array(value) }.select { |row| row.is_a?(Hash) }
    end

    def normalize_object_detections(*values, limit: 120)
      rows = normalize_hash_array(*values).map do |row|
        label = (row[:label] || row["label"] || row[:description] || row["description"]).to_s.strip
        next if label.blank?

        {
          label: label,
          confidence: (row[:confidence] || row["confidence"] || row[:score] || row["score"] || row[:max_confidence] || row["max_confidence"]).to_f,
          bbox: row[:bbox].is_a?(Hash) ? row[:bbox] : (row["bbox"].is_a?(Hash) ? row["bbox"] : {}),
          timestamps: Array(row[:timestamps] || row["timestamps"]).map(&:to_f).first(80)
        }
      end.compact

      rows
        .uniq { |row| [row[:label], row[:bbox], row[:timestamps].first(6)] }
        .sort_by { |row| -row[:confidence].to_f }
        .first(limit.to_i.clamp(1, 300))
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
      end.uniq { |row| [row[:person_id], row[:role], row[:similarity].to_f.round(3), row[:label]] }
    end

    def extract_source_account_reference(raw, story_meta)
      value = raw["story_ref"].to_s.presence || story_meta["story_ref"].to_s.presence
      value = value.delete_suffix(":") if value.to_s.present?
      return value if value.to_s.present?

      url = raw["story_url"].to_s.presence || raw["permalink"].to_s.presence || story_meta["story_url"].to_s.presence
      return nil if url.blank?

      match = url.match(%r{instagram\.com/stories/([a-zA-Z0-9._]+)/?}i) || url.match(%r{instagram\.com/([a-zA-Z0-9._]+)/?}i)
      match ? match[1].to_s.downcase : nil
    end

    def extract_source_profile_ids_from_metadata(raw, story_meta)
      rows = []
      %w[source_profile_id owner_id profile_id user_id source_user_id].each do |key|
        value = raw[key] || story_meta[key]
        rows << value.to_s if value.to_s.match?(/\A\d+\z/)
      end
      story_id = raw["story_id"].to_s.presence || story_meta["story_id"].to_s
      story_id.to_s.scan(/(?<!\w)\d{5,}(?!\w)/).each { |token| rows << token }
      rows.uniq.first(10)
    end
  end
end
