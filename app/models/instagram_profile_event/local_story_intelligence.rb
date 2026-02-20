require 'active_support/concern'

module InstagramProfileEvent::LocalStoryIntelligence
  extend ActiveSupport::Concern

  included do
    class LocalStoryIntelligenceUnavailableError < StandardError
      attr_reader :reason, :source

      def initialize(message = nil, reason: nil, source: nil)
        @reason = reason.to_s.presence
        @source = source.to_s.presence
        super(message || "Local story intelligence unavailable")
      end
    end
    def local_story_intelligence_payload
      raw = metadata.is_a?(Hash) ? metadata : {}
      story = instagram_stories.order(updated_at: :desc, id: :desc).first
      story_meta = story&.metadata.is_a?(Hash) ? story.metadata : {}
      story_embedded = story_meta["content_understanding"].is_a?(Hash) ? story_meta["content_understanding"] : {}
      event_embedded = raw["local_story_intelligence"].is_a?(Hash) ? raw["local_story_intelligence"] : {}
      embedded = story_embedded.presence || event_embedded.presence || {}

      ocr_text = first_present(
        embedded["ocr_text"],
        event_embedded["ocr_text"],
        story_meta["ocr_text"],
        raw["ocr_text"]
      )
      transcript = first_present(
        embedded["transcript"],
        event_embedded["transcript"],
        story_meta["transcript"],
        raw["transcript"]
      )
      objects = merge_unique_values(
        embedded["objects"],
        event_embedded["objects"],
        story_meta["content_signals"],
        raw["content_signals"]
      )
      hashtags = merge_unique_values(
        embedded["hashtags"],
        event_embedded["hashtags"],
        story_meta["hashtags"],
        raw["hashtags"]
      )
      mentions = merge_unique_values(
        embedded["mentions"],
        event_embedded["mentions"],
        story_meta["mentions"],
        raw["mentions"]
      )
      profile_handles = merge_unique_values(
        embedded["profile_handles"],
        event_embedded["profile_handles"],
        story_meta["profile_handles"],
        raw["profile_handles"]
      )
      scenes = normalize_hash_array(
        embedded["scenes"],
        event_embedded["scenes"],
        story_meta["scenes"],
        raw["scenes"]
      )
      ocr_blocks = normalize_hash_array(
        embedded["ocr_blocks"],
        event_embedded["ocr_blocks"],
        story_meta["ocr_blocks"],
        raw["ocr_blocks"]
      )
      ocr_text_from_blocks = ocr_blocks
        .map { |row| row.is_a?(Hash) ? (row["text"] || row[:text]) : nil }
        .map(&:to_s)
        .map(&:strip)
        .reject(&:blank?)
        .uniq
        .join("\n")
        .presence
      ocr_text = first_present(ocr_text, ocr_text_from_blocks)
      if hashtags.empty? && ocr_text.to_s.present?
        hashtags = ocr_text.to_s.scan(/#[a-zA-Z0-9_]+/).map(&:downcase).uniq.first(20)
      end
      if mentions.empty? && ocr_text.to_s.present?
        mentions = ocr_text.to_s.scan(/@[a-zA-Z0-9._]+/).map(&:downcase).uniq.first(20)
      end
      if profile_handles.empty? && ocr_text.to_s.present?
        profile_handles = ocr_text.to_s.scan(/\b[a-zA-Z0-9._]{3,30}\b/)
          .map(&:downcase)
          .select { |token| token.include?("_") || token.include?(".") }
          .reject { |token| token.include?("instagram.com") }
          .uniq
          .first(30)
      end
      object_detections = normalize_hash_array(
        embedded["object_detections"],
        event_embedded["object_detections"],
        story_meta["object_detections"],
        raw["object_detections"]
      )
      detected_object_labels = object_detections
        .map { |row| row.is_a?(Hash) ? (row[:label] || row["label"] || row[:description] || row["description"]) : nil }
        .map(&:to_s)
        .map(&:strip)
        .reject(&:blank?)
      objects = merge_unique_values(objects, detected_object_labels)
      topics = merge_unique_values(
        embedded["topics"],
        objects,
        hashtags.map { |tag| tag.to_s.delete_prefix("#") }
      )

      normalized_people = normalize_people_rows(
        event_embedded["people"],
        raw["face_people"],
        raw["people"],
        story_meta["face_people"],
        story_meta["participants"],
        story_meta.dig("face_identity", "participants"),
        raw["participants"],
        raw.dig("face_identity", "participants")
      )
      computed_face_count = [
        (event_embedded["face_count"] || embedded["faces_count"] || raw["face_count"]).to_i,
        normalized_people.size
      ].max

      payload = {
        ocr_text: ocr_text.to_s.presence,
        transcript: transcript.to_s.presence,
        objects: objects,
        hashtags: hashtags,
        mentions: mentions,
        profile_handles: profile_handles,
        topics: topics,
        scenes: scenes.first(80),
        ocr_blocks: ocr_blocks.first(120),
        object_detections: normalize_object_detections(object_detections, limit: 120),
        face_count: computed_face_count,
        people: normalized_people.first(12),
        source_account_reference: extract_source_account_reference(raw: raw, story_meta: story_meta),
        source_profile_ids: extract_source_profile_ids_from_metadata(raw: raw, story_meta: story_meta),
        media_type: raw["media_type"].to_s.presence || story_meta["media_type"].to_s.presence || media&.blob&.content_type.to_s.presence,
        source: if story_embedded.present?
          "story_processing"
        elsif event_embedded.present?
          "event_local_pipeline"
        else
          "event_metadata"
        end
      }

      needs_structured_enrichment =
        media.attached? &&
        Array(payload[:object_detections]).empty? &&
        Array(payload[:ocr_blocks]).empty? &&
        Array(payload[:scenes]).empty?

      if needs_structured_enrichment
        extracted = extract_live_local_intelligence_from_event_media(story_id: raw["story_id"].to_s.presence || id.to_s)
        if extracted.is_a?(Hash)
          merged_scenes = normalize_hash_array(payload[:scenes], extracted[:scenes]).first(80)
          merged_ocr_blocks = normalize_hash_array(payload[:ocr_blocks], extracted[:ocr_blocks]).first(120)
          merged_object_detections = normalize_object_detections(payload[:object_detections], extracted[:object_detections], limit: 120)

          payload[:scenes] = merged_scenes
          payload[:ocr_blocks] = merged_ocr_blocks
          payload[:object_detections] = merged_object_detections

          if merged_scenes.any? || merged_ocr_blocks.any? || merged_object_detections.any?
            payload[:source] = "live_local_enrichment"
          end
        end
      end

      if local_story_intelligence_blank?(payload) && media.attached?
        extracted = extract_live_local_intelligence_from_event_media(story_id: raw["story_id"].to_s.presence || id.to_s)
        if extracted.is_a?(Hash)
          if !local_story_intelligence_blank?(extracted)
            payload = extracted
          elsif extracted[:reason].to_s.present?
            payload[:reason] = extracted[:reason].to_s
          end
        end
      end

      if local_story_intelligence_blank?(payload)
        payload[:source] = "unavailable"
        payload[:reason] = payload[:reason].to_s.presence || "local_ai_extraction_empty"
      end

      payload
    rescue StandardError
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
    def persist_local_story_intelligence!(payload)
      return unless payload.is_a?(Hash)
      source = payload[:source].to_s
      return if source.blank? || source == "unavailable"

      current_meta = metadata.is_a?(Hash) ? metadata.deep_dup : {}
      current_intel = current_meta["local_story_intelligence"].is_a?(Hash) ? current_meta["local_story_intelligence"] : {}

      current_meta["ocr_text"] = payload[:ocr_text].to_s if payload[:ocr_text].present?
      current_meta["transcript"] = payload[:transcript].to_s if payload[:transcript].present?
      current_meta["content_signals"] = Array(payload[:objects]).map(&:to_s).reject(&:blank?).first(40)
      current_meta["hashtags"] = Array(payload[:hashtags]).map(&:to_s).reject(&:blank?).first(20)
      current_meta["mentions"] = Array(payload[:mentions]).map(&:to_s).reject(&:blank?).first(20)
      current_meta["profile_handles"] = Array(payload[:profile_handles]).map(&:to_s).reject(&:blank?).first(30)
      current_meta["topics"] = Array(payload[:topics]).map(&:to_s).reject(&:blank?).first(40)
      current_meta["scenes"] = normalize_hash_array(payload[:scenes]).first(80)
      current_meta["ocr_blocks"] = normalize_hash_array(payload[:ocr_blocks]).first(120)
      current_meta["object_detections"] = normalize_object_detections(payload[:object_detections], limit: 120)
      current_meta["face_count"] = payload[:face_count].to_i if payload[:face_count].to_i.positive?
      current_meta["face_people"] = Array(payload[:people]).first(12) if Array(payload[:people]).any?
      current_meta["local_story_intelligence"] = {
        "source" => source,
        "captured_at" => Time.current.iso8601,
        "ocr_text" => payload[:ocr_text].to_s.presence,
        "transcript" => payload[:transcript].to_s.presence,
        "objects" => Array(payload[:objects]).first(40),
        "hashtags" => Array(payload[:hashtags]).first(30),
        "mentions" => Array(payload[:mentions]).first(30),
        "profile_handles" => Array(payload[:profile_handles]).first(30),
        "topics" => Array(payload[:topics]).first(40),
        "scenes" => normalize_hash_array(payload[:scenes]).first(80),
        "ocr_blocks" => normalize_hash_array(payload[:ocr_blocks]).first(120),
        "object_detections" => normalize_object_detections(payload[:object_detections], limit: 120),
        "face_count" => payload[:face_count].to_i,
        "people" => Array(payload[:people]).first(12)
      }
      current_meta["local_story_intelligence_history_appended_at"] = Time.current.iso8601

      update_columns(metadata: current_meta, updated_at: Time.current)
      ownership = current_meta["story_ownership_classification"].is_a?(Hash) ? current_meta["story_ownership_classification"] : {}
      policy = current_meta["story_generation_policy"].is_a?(Hash) ? current_meta["story_generation_policy"] : {}
      return if story_excluded_from_narrative?(ownership: ownership, policy: policy)

      history_payload = payload.merge(description: build_story_image_description(local_story_intelligence: payload))
      AppendProfileHistoryNarrativeJob.perform_later(
        instagram_profile_event_id: id,
        mode: "story_intelligence",
        intelligence: history_payload
      )
    rescue StandardError
      nil
    end
    def persist_validated_story_insights!(payload)
      return unless payload.is_a?(Hash)
      verified_story_facts = payload[:verified_story_facts].is_a?(Hash) ? payload[:verified_story_facts] : {}
      ownership_classification = payload[:ownership_classification].is_a?(Hash) ? payload[:ownership_classification] : {}
      generation_policy = payload[:generation_policy].is_a?(Hash) ? payload[:generation_policy] : {}
      return if verified_story_facts.blank? && ownership_classification.blank? && generation_policy.blank?

      signature_payload = {
        verified_story_facts: build_cv_ocr_evidence(local_story_intelligence: verified_story_facts),
        ownership_classification: ownership_classification,
        generation_policy: generation_policy
      }
      signature = Digest::SHA256.hexdigest(signature_payload.to_json)

      current_meta = metadata.is_a?(Hash) ? metadata.deep_dup : {}
      stored = current_meta["validated_story_insights"].is_a?(Hash) ? current_meta["validated_story_insights"] : {}
      return if stored["signature"].to_s == signature

      current_meta["validated_story_insights"] = {
        "signature" => signature,
        "validated_at" => Time.current.iso8601,
        "verified_story_facts" => verified_story_facts,
        "ownership_classification" => ownership_classification,
        "generation_policy" => generation_policy
      }
      current_meta["story_ownership_classification"] = ownership_classification
      current_meta["story_generation_policy"] = generation_policy
      current_meta["detected_external_usernames"] = Array(ownership_classification[:detected_external_usernames] || ownership_classification["detected_external_usernames"]).map(&:to_s).first(12)
      source_profile_references = Array(ownership_classification[:source_profile_references] || ownership_classification["source_profile_references"] || verified_story_facts[:source_profile_references] || verified_story_facts["source_profile_references"]).map(&:to_s).reject(&:blank?).first(20)
      source_profile_ids = Array(ownership_classification[:source_profile_ids] || ownership_classification["source_profile_ids"] || verified_story_facts[:source_profile_ids] || verified_story_facts["source_profile_ids"]).map(&:to_s).reject(&:blank?).first(20)
      share_status = (ownership_classification[:share_status] || ownership_classification["share_status"]).to_s.presence || "unknown"
      allow_comment_value = if generation_policy.key?(:allow_comment)
        generation_policy[:allow_comment]
      else
        generation_policy["allow_comment"]
      end
      excluded_from_narrative = story_excluded_from_narrative?(ownership: ownership_classification, policy: generation_policy)
      current_meta["source_profile_references"] = source_profile_references
      current_meta["source_profile_ids"] = source_profile_ids
      current_meta["share_status"] = share_status
      current_meta["analysis_excluded"] = excluded_from_narrative
      current_meta["analysis_exclusion_reason"] = if excluded_from_narrative
        ownership_classification[:summary].to_s.presence || ownership_classification["summary"].to_s.presence || generation_policy[:reason].to_s.presence || generation_policy["reason"].to_s.presence
      end
      current_meta["content_classification"] = {
        "share_status" => share_status,
        "ownership_label" => ownership_classification[:label] || ownership_classification["label"],
        "allow_comment" => ActiveModel::Type::Boolean.new.cast(allow_comment_value),
        "source_profile_references" => source_profile_references,
        "source_profile_ids" => source_profile_ids
      }
      update_columns(metadata: current_meta, updated_at: Time.current)

      return if excluded_from_narrative

      history_payload = verified_story_facts.merge(
        ownership_classification: ownership_classification[:label] || ownership_classification["label"],
        ownership_summary: ownership_classification[:summary] || ownership_classification["summary"],
        ownership_confidence: ownership_classification[:confidence] || ownership_classification["confidence"],
        ownership_reason_codes: Array(ownership_classification[:reason_codes] || ownership_classification["reason_codes"]).first(12),
        generation_policy: generation_policy,
        description: build_story_image_description(local_story_intelligence: verified_story_facts)
      )
      AppendProfileHistoryNarrativeJob.perform_later(
        instagram_profile_event_id: id,
        mode: "story_intelligence",
        intelligence: history_payload
      )
    rescue StandardError
      nil
    end
    def build_story_image_description(local_story_intelligence:)
      signals = Array(local_story_intelligence[:objects]).first(6)
      if signals.empty?
        signals = Array(local_story_intelligence[:object_detections])
          .map { |row| row.is_a?(Hash) ? (row[:label] || row["label"]) : nil }
          .map(&:to_s)
          .map(&:strip)
          .reject(&:blank?)
          .uniq
          .first(6)
      end
      ocr = local_story_intelligence[:ocr_text].to_s.strip
      transcript = local_story_intelligence[:transcript].to_s.strip
      topic_text = Array(local_story_intelligence[:topics]).first(5).join(", ")
      scene_count = Array(local_story_intelligence[:scenes]).length
      face_count = local_story_intelligence[:face_count].to_i

      parts = []
      parts << "Detected visual signals: #{signals.join(', ')}." if signals.any?
      parts << "Detected scene transitions: #{scene_count}." if scene_count.positive?
      parts << "Detected faces: #{face_count}." if face_count.positive?
      parts << "OCR text: #{ocr}." if ocr.present?
      parts << "Audio transcript: #{transcript}." if transcript.present?
      parts << "Inferred topics: #{topic_text}." if topic_text.present?
      parts << "Story media context extracted from local AI pipeline." if parts.empty?
      parts.join(" ")
    end
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
    def apply_historical_validation(validated_story_insights:, historical_comparison:)
      insights = validated_story_insights.is_a?(Hash) ? validated_story_insights.deep_dup : {}
      ownership = insights[:ownership_classification].is_a?(Hash) ? insights[:ownership_classification] : {}
      policy = insights[:generation_policy].is_a?(Hash) ? insights[:generation_policy] : {}

      has_overlap = ActiveModel::Type::Boolean.new.cast(historical_comparison[:has_historical_overlap])
      external_usernames = Array(ownership[:detected_external_usernames]).map(&:to_s).reject(&:blank?)
      if ownership[:label].to_s == "owned_by_profile" && !has_overlap && external_usernames.any?
        ownership[:label] = "third_party_content"
        ownership[:decision] = "skip_comment"
        ownership[:reason_codes] = Array(ownership[:reason_codes]) + [ "no_historical_overlap_with_external_usernames" ]
        ownership[:summary] = "Detected external usernames without historical overlap; classified as third-party content."
        policy[:allow_comment] = false
        policy[:reason_code] = "no_historical_overlap_with_external_usernames"
        policy[:reason] = ownership[:summary]
        policy[:classification] = ownership[:label]
      end
      policy[:historical_overlap] = has_overlap

      insights[:ownership_classification] = ownership
      insights[:generation_policy] = policy
      insights
    rescue StandardError
      validated_story_insights
    end
    def local_story_intelligence_blank?(payload)
      return true unless payload.is_a?(Hash)

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
    def extract_live_local_intelligence_from_event_media(story_id:)
      content_type = media&.blob&.content_type.to_s
      return {} if content_type.blank?

      if content_type.start_with?("image/")
        extract_local_intelligence_from_image_bytes(image_bytes: media.download, story_id: story_id)
      elsif content_type.start_with?("video/")
        extract_local_intelligence_from_video_bytes(video_bytes: media.download, story_id: story_id, content_type: content_type)
      else
        {}
      end
    rescue StandardError
      {}
    end
    def extract_local_intelligence_from_image_bytes(image_bytes:, story_id:)
      detection = FaceDetectionService.new.detect(
        media_payload: { story_id: story_id.to_s, image_bytes: image_bytes }
      )
      understanding = StoryContentUnderstandingService.new.build(
        media_type: "image",
        detections: [detection],
        transcript_text: nil
      )
      people = resolve_people_from_faces(detected_faces: Array(detection[:faces]), fallback_image_bytes: image_bytes, story_id: story_id)

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
        object_detections: normalize_object_detections(understanding[:object_detections], limit: 120),
        face_count: Array(detection[:faces]).length,
        people: people,
        reason: detection.dig(:metadata, :reason).to_s.presence,
        source: "live_local_vision_ocr"
      }
    end
    def extract_local_intelligence_from_video_bytes(video_bytes:, story_id:, content_type:)
      frame_result = VideoFrameExtractionService.new.extract(
        video_bytes: video_bytes,
        story_id: story_id.to_s,
        content_type: content_type.to_s
      )
      detections = []
      faces = []

      Array(frame_result[:frames]).first(8).each do |frame|
        detection = FaceDetectionService.new.detect(
          media_payload: { story_id: story_id.to_s, image_bytes: frame[:image_bytes] }
        )
        detections << detection
        Array(detection[:faces]).each { |face| faces << face.merge(image_bytes: frame[:image_bytes]) }
      end

      audio_result = VideoAudioExtractionService.new.extract(
        video_bytes: video_bytes,
        story_id: story_id.to_s,
        content_type: content_type.to_s
      )
      transcript = SpeechTranscriptionService.new.transcribe(
        audio_bytes: audio_result[:audio_bytes],
        story_id: story_id.to_s
      )
      video_intel = Ai::LocalMicroserviceClient.new.analyze_video_story_intelligence!(
        video_bytes: video_bytes,
        sample_rate: 2,
        usage_context: { workflow: "story_processing", story_id: story_id.to_s }
      ) rescue {}

      understanding = StoryContentUnderstandingService.new.build(
        media_type: "video",
        detections: detections,
        transcript_text: transcript[:transcript]
      )

      people = resolve_people_from_faces(
        detected_faces: faces,
        fallback_image_bytes: faces.first&.dig(:image_bytes),
        story_id: story_id
      )

      {
        ocr_text: understanding[:ocr_text].to_s.presence,
        transcript: understanding[:transcript].to_s.presence,
        objects: Array(understanding[:objects]).map(&:to_s).reject(&:blank?).uniq.first(40),
        hashtags: Array(understanding[:hashtags]).map(&:to_s).reject(&:blank?).uniq.first(25),
        mentions: Array(understanding[:mentions]).map(&:to_s).reject(&:blank?).uniq.first(25),
        profile_handles: Array(understanding[:profile_handles]).map(&:to_s).reject(&:blank?).uniq.first(40),
        topics: Array(understanding[:topics]).map(&:to_s).reject(&:blank?).uniq.first(40),
        scenes: normalize_hash_array(understanding[:scenes], video_intel["scenes"]).first(80),
        ocr_blocks: normalize_hash_array(understanding[:ocr_blocks], video_intel["ocr_blocks"]).first(120),
        object_detections: normalize_object_detections(understanding[:object_detections], video_intel["object_detections"], limit: 120),
        face_count: faces.length,
        people: people,
        reason: [ frame_result.dig(:metadata, :reason), audio_result.dig(:metadata, :reason), transcript.dig(:metadata, :reason) ]
          .map(&:to_s)
          .reject(&:blank?)
          .uniq
          .join(", ")
          .presence,
        source: "live_local_video_vision_ocr_transcript"
      }
    end

  end
end
