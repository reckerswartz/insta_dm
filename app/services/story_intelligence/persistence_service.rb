# frozen_string_literal: true
require "digest"

module StoryIntelligence
  # Service for persisting story intelligence data
  # Extracted from InstagramProfileEvent::LocalStoryIntelligence to follow Single Responsibility Principle
  class PersistenceService
    include ActiveModel::Validations

    def initialize(event:)
      @event = event
    end

    def persist_local_intelligence!(payload)
      return unless valid_payload?(payload)
      return if unavailable_source?(payload)

      normalized_payload = payload.deep_symbolize_keys
      history_payload = nil

      event.with_lock do
        event.reload
        current_meta = event.metadata.is_a?(Hash) ? event.metadata.deep_dup : {}
        update_metadata_with_intelligence(current_meta, normalized_payload)

        ownership = current_meta["story_ownership_classification"].is_a?(Hash) ? current_meta["story_ownership_classification"] : {}
        policy = current_meta["story_generation_policy"].is_a?(Hash) ? current_meta["story_generation_policy"] : {}
        unless story_excluded_from_narrative?(ownership: ownership, policy: policy)
          history_payload = normalized_payload.merge(description: build_story_image_description(normalized_payload))
        end

        event.update_columns(metadata: current_meta, updated_at: Time.current)
      end

      sync_insight_store!(intelligence: normalized_payload)

      return if history_payload.blank?

      enqueue_story_intelligence_narrative_once!(history_payload)
    end

    def persist_validated_insights!(payload)
      return unless valid_insights_payload?(payload)

      insights = extract_insights(payload)
      return if insights_blank?(insights)
      history_payload = nil
      should_enqueue = false

      event.with_lock do
        event.reload
        current_meta = event.metadata.is_a?(Hash) ? event.metadata.deep_dup : {}
        signature = generate_insights_signature(insights)
        stored = current_meta["validated_story_insights"].is_a?(Hash) ? current_meta["validated_story_insights"] : {}
        next if stored["signature"].to_s == signature

        update_metadata_with_insights(current_meta, insights, signature)
        excluded_from_narrative = update_content_classification(current_meta, insights)
        event.update_columns(metadata: current_meta, updated_at: Time.current)

        unless excluded_from_narrative
          ownership = insights[:ownership_classification]
          policy = insights[:generation_policy]
          verified_facts = insights[:verified_story_facts]
          history_payload = verified_facts.merge(
            ownership_classification: ownership[:label] || ownership["label"],
            ownership_summary: ownership[:summary] || ownership["summary"],
            ownership_confidence: ownership[:confidence] || ownership["confidence"],
            ownership_reason_codes: Array(ownership[:reason_codes] || ownership["reason_codes"]).first(12),
            generation_policy: policy,
            description: build_story_image_description(verified_facts)
          )
          should_enqueue = true
        end
      end

      sync_insight_store!(intelligence: insights[:verified_story_facts])

      enqueue_story_intelligence_narrative_once!(history_payload) if should_enqueue
    end

    private

    attr_reader :event

    def valid_payload?(payload)
      payload.is_a?(Hash)
    end

    def unavailable_source?(payload)
      payload[:source].to_s.blank? || payload[:source] == "unavailable"
    end

    def update_metadata_with_intelligence(current_meta, payload)
      update_basic_intelligence_fields(current_meta, payload)
      update_detailed_intelligence_fields(current_meta, payload)
      update_intelligence_snapshot(current_meta, payload)
    end

    def update_basic_intelligence_fields(current_meta, payload)
      current_meta["ocr_text"] = payload[:ocr_text].to_s if payload[:ocr_text].present?
      current_meta["transcript"] = payload[:transcript].to_s if payload[:transcript].present?
      current_meta["content_signals"] = Array(payload[:objects]).map(&:to_s).reject(&:blank?).first(40)
      current_meta["hashtags"] = Array(payload[:hashtags]).map(&:to_s).reject(&:blank?).first(20)
      current_meta["mentions"] = Array(payload[:mentions]).map(&:to_s).reject(&:blank?).first(20)
      current_meta["profile_handles"] = Array(payload[:profile_handles]).map(&:to_s).reject(&:blank?).first(30)
      current_meta["topics"] = Array(payload[:topics]).map(&:to_s).reject(&:blank?).first(40)
      current_meta["face_count"] = payload[:face_count].to_i if payload[:face_count].to_i.positive?
      current_meta["face_people"] = Array(payload[:people]).first(12) if Array(payload[:people]).any?
    end

    def update_detailed_intelligence_fields(current_meta, payload)
      current_meta["scenes"] = normalize_hash_array(payload[:scenes]).first(80)
      current_meta["ocr_blocks"] = normalize_hash_array(payload[:ocr_blocks]).first(120)
      current_meta["object_detections"] = normalize_object_detections(payload[:object_detections], limit: 120)
    end

    def update_intelligence_snapshot(current_meta, payload)
      current_meta["local_story_intelligence"] = {
        "source" => payload[:source].to_s,
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
    end

    def valid_insights_payload?(payload)
      payload.is_a?(Hash)
    end

    def extract_insights(payload)
      {
        verified_story_facts: payload[:verified_story_facts].is_a?(Hash) ? payload[:verified_story_facts] : {},
        ownership_classification: payload[:ownership_classification].is_a?(Hash) ? payload[:ownership_classification] : {},
        generation_policy: payload[:generation_policy].is_a?(Hash) ? payload[:generation_policy] : {}
      }
    end

    def insights_blank?(insights)
      insights[:verified_story_facts].blank? && 
      insights[:ownership_classification].blank? && 
      insights[:generation_policy].blank?
    end

    def generate_insights_signature(insights)
      signature_payload = {
        verified_story_facts: event.send(:build_cv_ocr_evidence, local_story_intelligence: insights[:verified_story_facts]),
        ownership_classification: insights[:ownership_classification],
        generation_policy: insights[:generation_policy]
      }
      Digest::SHA256.hexdigest(signature_payload.to_json)
    end

    def update_metadata_with_insights(current_meta, insights, signature)
      current_meta["validated_story_insights"] = {
        "signature" => signature,
        "validated_at" => Time.current.iso8601,
        "verified_story_facts" => insights[:verified_story_facts],
        "ownership_classification" => insights[:ownership_classification],
        "generation_policy" => insights[:generation_policy]
      }

      current_meta["story_ownership_classification"] = insights[:ownership_classification]
      current_meta["story_generation_policy"] = insights[:generation_policy]
    end

    def update_content_classification(current_meta, insights)
      ownership = insights[:ownership_classification]
      policy = insights[:generation_policy]
      verified_facts = insights[:verified_story_facts]

      current_meta["detected_external_usernames"] = Array(ownership[:detected_external_usernames] || ownership["detected_external_usernames"]).map(&:to_s).first(12)
      
      source_profile_references = extract_source_profile_references(ownership, verified_facts)
      source_profile_ids = extract_source_profile_ids(ownership, verified_facts)
      
      share_status = determine_share_status(ownership)
      allow_comment_value = determine_allow_comment_value(policy)
      
      excluded_from_narrative = story_excluded_from_narrative?(ownership: ownership, policy: policy)

      current_meta["source_profile_references"] = source_profile_references
      current_meta["source_profile_ids"] = source_profile_ids
      current_meta["share_status"] = share_status
      current_meta["analysis_excluded"] = excluded_from_narrative
      current_meta["analysis_exclusion_reason"] = determine_exclusion_reason(ownership, policy, excluded_from_narrative)
      
      current_meta["content_classification"] = {
        "share_status" => share_status,
        "ownership_label" => ownership[:label] || ownership["label"],
        "allow_comment" => ActiveModel::Type::Boolean.new.cast(allow_comment_value),
        "source_profile_references" => source_profile_references,
        "source_profile_ids" => source_profile_ids
      }

      excluded_from_narrative
    end

    def extract_source_profile_references(ownership, verified_facts)
      Array(ownership[:source_profile_references] || ownership["source_profile_references"] || 
            verified_facts[:source_profile_references] || verified_facts["source_profile_references"])
        .map(&:to_s).reject(&:blank?).first(20)
    end

    def extract_source_profile_ids(ownership, verified_facts)
      Array(ownership[:source_profile_ids] || ownership["source_profile_ids"] || 
            verified_facts[:source_profile_ids] || verified_facts["source_profile_ids"])
        .map(&:to_s).reject(&:blank?).first(20)
    end

    def determine_share_status(ownership)
      (ownership[:share_status] || ownership["share_status"]).to_s.presence || "unknown"
    end

    def determine_allow_comment_value(policy)
      if policy.key?(:allow_comment)
        policy[:allow_comment]
      else
        policy["allow_comment"]
      end
    end

    def determine_exclusion_reason(ownership, policy, excluded)
      return unless excluded
      
      ownership[:summary].to_s.presence || ownership["summary"].to_s.presence || 
      policy[:reason].to_s.presence || policy["reason"].to_s.presence
    end

    def enqueue_story_intelligence_narrative_once!(history_payload)
      return unless history_payload.is_a?(Hash)

      payload = history_payload.deep_symbolize_keys
      fingerprint = Digest::SHA256.hexdigest(payload.to_json)
      enqueue = false

      event.with_lock do
        event.reload
        current_meta = event.metadata.is_a?(Hash) ? event.metadata.deep_dup : {}
        fingerprints = Array(current_meta["story_intelligence_narrative_fingerprints"]).map(&:to_s)
        next if fingerprints.include?(fingerprint)

        current_meta["story_intelligence_narrative_fingerprints"] = (fingerprints << fingerprint).last(50)
        current_meta["story_intelligence_history_appended_at"] = Time.current.iso8601
        event.update_columns(metadata: current_meta, updated_at: Time.current)
        enqueue = true
      end

      return unless enqueue

      AppendProfileHistoryNarrativeJob.perform_later(
        instagram_profile_event_id: event.id,
        mode: "story_intelligence",
        intelligence: payload
      )
    rescue StandardError
      nil
    end

    def sync_insight_store!(intelligence:)
      payload = intelligence.is_a?(Hash) ? intelligence.deep_stringify_keys : {}
      return if payload.blank?

      profile = event.instagram_profile
      return unless profile

      Ai::ProfileInsightStore.new.ingest_story!(
        profile: profile,
        event: event,
        intelligence: payload
      )
    rescue StandardError
      nil
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

    def build_story_image_description(local_story_intelligence)
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

    # Helper methods (these would be extracted to a utility module)
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
  end
end
