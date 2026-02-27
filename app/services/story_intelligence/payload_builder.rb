# frozen_string_literal: true

module StoryIntelligence
  # Service for building story intelligence payloads
  # Extracted from InstagramProfileEvent::LocalStoryIntelligence to follow Single Responsibility Principle
  class PayloadBuilder
    include ActiveModel::Validations

    SUMMARY_TOPIC_STOPWORDS = %w[
      about after again against along also and are around because been before being between
      both but can could does doing down during each few from have having into itself just
      like many more most much only other over same should some such than that their there
      these they this those through under very what when where which while with without your
      image video story frame scene visual context detected looks showing appears includes
      instagram post clip
    ].freeze

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
      payload[:ocr_text] = first_present(payload[:ocr_text], extracted[:ocr_text])
      payload[:transcript] = first_present(payload[:transcript], extracted[:transcript])
      payload[:objects] = merge_unique_values(
        payload[:objects],
        extracted[:objects],
        extract_object_labels(Array(extracted[:object_detections]))
      )
      payload[:hashtags] = merge_unique_values(payload[:hashtags], extracted[:hashtags])
      payload[:mentions] = merge_unique_values(payload[:mentions], extracted[:mentions])
      payload[:profile_handles] = merge_unique_values(payload[:profile_handles], extracted[:profile_handles])
      payload[:topics] = merge_unique_values(
        payload[:topics],
        extracted[:topics],
        payload[:objects],
        Array(payload[:hashtags]).map { |tag| tag.to_s.delete_prefix("#") }
      )
      payload[:face_count] = [ payload[:face_count].to_i, extracted[:face_count].to_i ].max
      payload[:people] = normalize_people_rows(payload[:people], extracted[:people]).first(12)
      payload[:scenes] = normalize_hash_array(payload[:scenes], extracted[:scenes]).first(80)
      payload[:ocr_blocks] = normalize_hash_array(payload[:ocr_blocks], extracted[:ocr_blocks]).first(120)
      payload[:object_detections] = normalize_object_detections(payload[:object_detections], extracted[:object_detections], limit: 120)
      payload[:processing_stages] = extracted[:processing_stages] if extracted[:processing_stages].is_a?(Hash)
      payload[:processing_log] = Array(extracted[:processing_log]).last(24) if extracted[:processing_log].is_a?(Array)
    end

    def update_source_if_enriched(payload, extracted)
      if enriched?(extracted)
        payload[:source] = extracted[:source].to_s.presence || "live_local_enrichment"
      end
    end

    def enriched?(extracted)
      extracted[:ocr_text].to_s.present? ||
        extracted[:transcript].to_s.present? ||
        Array(extracted[:scenes]).any? ||
        Array(extracted[:ocr_blocks]).any? ||
        Array(extracted[:object_detections]).any? ||
        Array(extracted[:objects]).any? ||
        Array(extracted[:topics]).any? ||
        Array(extracted[:hashtags]).any? ||
        Array(extracted[:mentions]).any? ||
        Array(extracted[:profile_handles]).any? ||
        extracted[:face_count].to_i.positive? ||
        Array(extracted[:people]).any?
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
    rescue StandardError => e
      unavailable_live_intelligence(
        reason: "llm_media_intelligence_unavailable",
        error: "#{e.class}: #{e.message}".byteslice(0, 240)
      )
    end

    def extract_image_intelligence(_story_id)
      image_bytes = event.media.download
      return unavailable_live_intelligence(reason: "image_bytes_missing") if image_bytes.to_s.b.blank?

      stage_started_at = monotonic_time
      vision = vision_understanding_service.summarize(
        image_bytes_list: [ image_bytes.to_s.b ],
        transcript: nil,
        candidate_topics: [],
        media_type: "image"
      )
      duration_ms = ((monotonic_time - stage_started_at) * 1000.0).round
      vision_meta = vision[:metadata].is_a?(Hash) ? vision[:metadata].deep_stringify_keys : {}
      summary = vision[:summary].to_s.strip
      summary_tokens = summary_topic_tokens(summary)
      hashtags = summary.scan(/#[a-zA-Z0-9_]+/).map(&:downcase).uniq.first(20)
      mentions = summary.scan(/@[a-zA-Z0-9._]+/).map(&:downcase).uniq.first(20)
      profile_handles = summary.scan(/\b[a-zA-Z0-9._]{3,30}\b/)
        .map(&:downcase)
        .select { |token| token.include?("_") || token.include?(".") }
        .reject { |token| token.include?("instagram.com") }
        .uniq
        .first(30)
      topics = merge_unique_values(vision[:topics], summary_tokens, hashtags.map { |tag| tag.to_s.delete_prefix("#") })
      objects = merge_unique_values(vision[:objects], topics.first(10))
      reason = vision_meta["reason"].to_s.presence

      processing_stages = {
        ocr_analysis: stage_row(
          label: "OCR Analysis",
          group: "media_analysis",
          state: "completed_with_warnings",
          progress: 100,
          message: "Dedicated OCR microservice disabled; visible text inferred from LLM vision context."
        ),
        vision_detection: stage_row(
          label: "Image Analysis",
          group: "media_analysis",
          state: topics.any? || objects.any? || summary.present? ? "completed" : "completed_with_warnings",
          progress: 100,
          message: topics.any? || objects.any? || summary.present? ? "LLM vision analysis completed." : "LLM vision analysis returned limited context."
        ),
        face_recognition: stage_row(
          label: "Face Recognition",
          group: "media_analysis",
          state: "completed_with_warnings",
          progress: 100,
          message: "Face microservice disabled; face-specific enrichment skipped."
        ),
        metadata_extraction: stage_row(
          label: "Metadata Extraction",
          group: "media_analysis",
          state: "completed",
          progress: 100,
          message: "Metadata extraction completed"
        ),
        parallel_services: stage_row(
          label: "Parallel AI Services",
          group: "media_analysis",
          state: "completed",
          progress: 100,
          message: "Media context extracted directly via LLM vision analysis.",
          details: {
            duration_ms: duration_ms,
            model: vision_meta["model"].to_s.presence,
            reason: reason
          }.compact
        )
      }

      payload = {
        ocr_text: nil,
        transcript: nil,
        objects: objects,
        hashtags: hashtags,
        mentions: mentions,
        profile_handles: profile_handles,
        topics: topics,
        scenes: [],
        ocr_blocks: [],
        object_detections: [],
        face_count: 0,
        people: [],
        reason: reason,
        source: "live_llm_vision_image_context",
        processing_stages: processing_stages,
        processing_log: [
          {
            stage: "llm_vision_extraction",
            state: topics.any? || objects.any? || summary.present? ? "completed" : "completed_with_warnings",
            progress: 100,
            message: summary.presence || "LLM vision extracted image context.",
            duration_ms: duration_ms,
            model: vision_meta["model"].to_s.presence,
            reason: reason
          }
        ]
      }

      if payload_blank?(payload)
        return {
          source: "unavailable",
          reason: reason.to_s.presence || "llm_image_intelligence_empty",
          processing_stages: payload[:processing_stages],
          processing_log: payload[:processing_log]
        }
      end

      payload.delete(:reason) if payload[:reason].to_s.blank?
      payload
    end

    def extract_video_intelligence(story_id, content_type)
      video_bytes = event.media.download
      extraction = llm_only_video_context_service.extract(
        video_bytes: video_bytes,
        reference_id: story_id.to_s,
        content_type: content_type
      )
      return {} unless extraction.is_a?(Hash)

      payload = {
        ocr_text: extraction[:ocr_text].to_s.presence,
        transcript: extraction[:transcript].to_s.presence,
        objects: merge_unique_values(extraction[:objects]),
        hashtags: merge_unique_values(extraction[:hashtags]),
        mentions: merge_unique_values(extraction[:mentions]),
        profile_handles: merge_unique_values(extraction[:profile_handles]),
        topics: merge_unique_values(
          extraction[:topics],
          extraction[:objects],
          Array(extraction[:hashtags]).map { |tag| tag.to_s.delete_prefix("#") }
        ),
        scenes: normalize_hash_array(extraction[:scenes]).first(80),
        ocr_blocks: normalize_hash_array(extraction[:ocr_blocks]).first(120),
        object_detections: normalize_object_detections(extraction[:object_detections], limit: 120),
        face_count: extraction[:face_count].to_i,
        people: normalize_people_rows(extraction[:people]).first(12),
        media_type: "video",
        source: "live_llm_video_context",
        reason: extraction_reason_from_metadata(extraction),
        processing_stages: video_processing_stages(extraction),
        processing_log: video_processing_log(extraction)
      }

      if payload_blank?(payload)
        return {
          source: "unavailable",
          reason: payload[:reason].to_s.presence || "video_context_extraction_empty",
          processing_stages: payload[:processing_stages],
          processing_log: payload[:processing_log]
        }
      end

      payload.delete(:reason) if payload[:reason].to_s.blank?
      payload
    end

    def video_processing_stages(extraction)
      metadata = extraction[:metadata].is_a?(Hash) ? extraction[:metadata].deep_stringify_keys : {}
      processing_mode = extraction[:processing_mode].to_s.presence || "dynamic_video"
      ocr_available = extraction[:ocr_text].to_s.present? || Array(extraction[:ocr_blocks]).any?
      visual_available = Array(extraction[:objects]).any? || Array(extraction[:topics]).any? || Array(extraction[:scenes]).any?
      faces_available = extraction[:face_count].to_i.positive? || Array(extraction[:people]).any?
      transcript_available = extraction[:transcript].to_s.present?
      audio_reason = metadata.dig("audio_extraction", "reason").to_s.presence
      transcription_reason = metadata.dig("transcription", "reason").to_s.presence
      visual_reason = if processing_mode == "static_image"
        metadata.dig("static_frame_intelligence", "reason").to_s.presence
      else
        metadata.dig("local_video_intelligence", "reason").to_s.presence
      end
      parallel_execution = metadata["parallel_execution"].is_a?(Hash) ? metadata["parallel_execution"] : {}

      {
        ocr_analysis: stage_row(
          label: "OCR Analysis",
          group: "media_analysis",
          state: ocr_available ? "completed" : "completed_with_warnings",
          progress: 100,
          message: ocr_available ? "Video OCR extraction completed." : "Video OCR returned no reliable text."
        ),
        vision_detection: stage_row(
          label: "Video Analysis",
          group: "media_analysis",
          state: visual_available ? "completed" : "completed_with_warnings",
          progress: 100,
          message: visual_available ? "Video context extraction completed." : "Video context extraction returned limited visual signals.",
          details: {
            processing_mode: processing_mode,
            reason: visual_reason
          }.compact
        ),
        face_recognition: stage_row(
          label: "Face Recognition",
          group: "media_analysis",
          state: faces_available ? "completed" : "completed_with_warnings",
          progress: 100,
          message: faces_available ? "Face signals extracted from video context." : "No usable face evidence detected."
        ),
        metadata_extraction: stage_row(
          label: "Metadata Extraction",
          group: "media_analysis",
          state: "completed",
          progress: 100,
          message: "Video processing metadata captured."
        ),
        audio_extraction: stage_row(
          label: "Audio Extraction",
          group: "media_analysis",
          state: audio_reason.in?(%w[no_audio_stream video_too_long_for_audio_extraction video_too_large_for_audio_extraction]) ? "skipped" : (audio_reason.present? ? "completed_with_warnings" : "completed"),
          progress: 100,
          message: audio_reason.present? ? "Audio extraction skipped (#{audio_reason.tr('_', ' ')})." : "Audio extraction completed."
        ),
        speech_transcription: stage_row(
          label: "Speech Transcription",
          group: "media_analysis",
          state: transcript_available ? "completed" : (transcription_reason.in?(%w[audio_unavailable no_audio_stream]) ? "skipped" : (transcription_reason.present? ? "completed_with_warnings" : "completed")),
          progress: 100,
          message: transcript_available ? "Speech transcription completed." : "Speech transcription unavailable#{transcription_reason.present? ? " (#{transcription_reason.tr('_', ' ')})" : ""}."
        ),
        parallel_services: stage_row(
          label: "Parallel AI Services",
          group: "media_analysis",
          state: parallel_execution["errors"].is_a?(Hash) && parallel_execution["errors"].present? ? "completed_with_warnings" : "completed",
          progress: 100,
          message: "Audio/transcription and video-analysis services executed in parallel.",
          details: {
            duration_ms: parallel_execution["duration_ms"],
            errors: parallel_execution["errors"]
          }.compact
        )
      }
    end

    def video_processing_log(extraction)
      metadata = extraction[:metadata].is_a?(Hash) ? extraction[:metadata].deep_stringify_keys : {}
      [ {
        stage: "video_context_extraction",
        state: ActiveModel::Type::Boolean.new.cast(extraction[:skipped]) ? "completed_with_warnings" : "completed",
        progress: 100,
        message: extraction[:context_summary].to_s.presence || "Video context extracted without frame-by-frame processing.",
        details: {
          processing_mode: extraction[:processing_mode].to_s.presence || "dynamic_video",
          semantic_route: extraction[:semantic_route].to_s.presence || "video",
          static: ActiveModel::Type::Boolean.new.cast(extraction[:static]),
          duration_seconds: extraction[:duration_seconds],
          has_audio: extraction[:has_audio],
          metadata_reason: metadata["reason"].to_s.presence,
          audio_reason: metadata.dig("audio_extraction", "reason").to_s.presence,
          transcription_reason: metadata.dig("transcription", "reason").to_s.presence,
          static_frame_reason: metadata.dig("static_frame_intelligence", "reason").to_s.presence,
          local_video_reason: metadata.dig("local_video_intelligence", "reason").to_s.presence,
          vision_reason: metadata.dig("vision_understanding", "reason").to_s.presence,
          vision_model: metadata.dig("vision_understanding", "model").to_s.presence,
          parallel_execution: metadata["parallel_execution"].is_a?(Hash) ? metadata["parallel_execution"] : nil
        }.compact
      } ]
    end

    def extraction_reason_from_metadata(extraction)
      metadata = extraction[:metadata].is_a?(Hash) ? extraction[:metadata].deep_stringify_keys : {}
      skipped = ActiveModel::Type::Boolean.new.cast(extraction[:skipped])
      ignore_reasons = %w[
        audio_unavailable
        no_audio_stream
        static_video_routed_to_image
        dynamic_video_no_static_frame_analysis
      ]
      candidates = [
        metadata["reason"],
        metadata.dig("vision_understanding", "reason"),
        metadata.dig("local_video_intelligence", "reason"),
        metadata.dig("static_frame_intelligence", "reason"),
        metadata.dig("transcription", "reason"),
        metadata.dig("audio_extraction", "reason")
      ]
      reasons = candidates.map(&:to_s).select(&:present?)
      return reasons.first if skipped

      reasons.find { |value| !ignore_reasons.include?(value) }
    end

    def stage_row(label:, group:, state:, progress:, message:, details: nil)
      {
        label: label.to_s,
        group: group.to_s,
        state: state,
        progress: progress.to_i.clamp(0, 100),
        message: message.to_s,
        updated_at: Time.current.iso8601(3),
        details: details
      }
    end

    def monotonic_time
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    rescue StandardError
      Time.current.to_f
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

    def vision_understanding_service
      @vision_understanding_service ||= Ai::VisionUnderstandingService.new
    end

    def llm_only_video_context_service
      @llm_only_video_context_service ||= PostVideoContextExtractionService.new
    end

    def unavailable_live_intelligence(reason:, error: nil)
      {
        source: "unavailable",
        reason: reason.to_s.presence || "local_ai_unavailable",
        error: error.to_s.presence
      }.compact
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

    def summary_topic_tokens(text)
      text.to_s.downcase.scan(/[a-z0-9_]+/)
        .reject { |token| token.length < 3 }
        .reject { |token| SUMMARY_TOPIC_STOPWORDS.include?(token) }
        .uniq
        .first(24)
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
