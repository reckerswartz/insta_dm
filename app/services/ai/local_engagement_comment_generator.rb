require "json"
require "net/http"

module Ai
  class LocalEngagementCommentGenerator
    DEFAULT_MODEL = "mistral:7b".freeze
    MIN_SUGGESTIONS = 3
    MAX_SUGGESTIONS = 8

    BLOCKED_TERMS = %w[].freeze
    TRANSIENT_ERRORS = [
      Net::OpenTimeout,
      Net::ReadTimeout,
      Errno::ECONNRESET,
      Errno::ECONNREFUSED
    ].freeze

    def initialize(ollama_client:, model: nil)
      @ollama_client = ollama_client
      @model = model.to_s.presence || DEFAULT_MODEL
    end

    def generate!(post_payload:, image_description:, topics:, author_type:, historical_comments: [], historical_context: nil, historical_story_context: [], local_story_intelligence: {}, historical_comparison: {}, cv_ocr_evidence: {}, verified_story_facts: {}, story_ownership_classification: {}, generation_policy: {}, **_extra)
      if generation_policy.is_a?(Hash) && generation_policy.key?(:allow_comment) && !ActiveModel::Type::Boolean.new.cast(generation_policy[:allow_comment] || generation_policy["allow_comment"])
        return {
          model: @model,
          prompt: nil,
          raw: {},
          source: "policy",
          status: "blocked_by_policy",
          fallback_used: false,
          error_message: generation_policy[:reason].to_s.presence || generation_policy["reason"].to_s.presence || "Generation blocked by verified story policy.",
          comment_suggestions: []
        }
      end

      prompt = build_prompt(
        post_payload: post_payload,
        image_description: image_description,
        topics: topics,
        author_type: author_type,
        historical_comments: historical_comments,
        historical_context: historical_context,
        historical_story_context: historical_story_context,
        local_story_intelligence: local_story_intelligence,
        historical_comparison: historical_comparison,
        cv_ocr_evidence: cv_ocr_evidence,
        verified_story_facts: verified_story_facts,
        story_ownership_classification: story_ownership_classification,
        generation_policy: generation_policy
      )

      resp = @ollama_client.generate(
        model: @model,
        prompt: prompt,
        temperature: 0.7,
        max_tokens: 300
      )

      suggestions = parse_comment_suggestions(resp)
      suggestions = filter_safe_comments(suggestions)

      if suggestions.size < MIN_SUGGESTIONS
        retry_resp = @ollama_client.generate(
          model: @model,
          prompt: "#{prompt}\n\nReturn strict JSON only. Ensure 8 non-empty suggestions.",
          temperature: 0.4,
          max_tokens: 220
        )
        retry_suggestions = filter_safe_comments(parse_comment_suggestions(retry_resp))
        suggestions = retry_suggestions if retry_suggestions.size >= MIN_SUGGESTIONS
      end

      if suggestions.size < MIN_SUGGESTIONS
        fallback = fallback_comments(image_description: image_description, topics: topics).first(MAX_SUGGESTIONS)
        return {
          model: @model,
          prompt: prompt,
          raw: resp,
          source: "fallback",
          status: "fallback_used",
          fallback_used: true,
          error_message: "Generated suggestions were insufficient (#{suggestions.size}/#{MIN_SUGGESTIONS})",
          comment_suggestions: fallback
        }
      end

      {
        model: @model,
        prompt: prompt,
        raw: resp,
        source: "ollama",
        status: "ok",
        fallback_used: false,
        error_message: nil,
        comment_suggestions: suggestions.first(MAX_SUGGESTIONS)
      }
    rescue *TRANSIENT_ERRORS
      raise
    rescue StandardError => e
      {
        model: @model,
        prompt: prompt,
        raw: {},
        source: "fallback",
        status: "error_fallback",
        fallback_used: true,
        error_message: e.message.to_s,
        comment_suggestions: fallback_comments(image_description: image_description, topics: topics).first(MAX_SUGGESTIONS)
      }
    end

    private

    def build_prompt(post_payload:, image_description:, topics:, author_type:, historical_comments:, historical_context:, historical_story_context:, local_story_intelligence:, historical_comparison:, cv_ocr_evidence:, verified_story_facts:, story_ownership_classification:, generation_policy:)
      verified_story_facts = compact_verified_story_facts(
        verified_story_facts,
        local_story_intelligence: local_story_intelligence,
        cv_ocr_evidence: cv_ocr_evidence
      )
      story_ownership_classification = compact_story_ownership_classification(story_ownership_classification)
      generation_policy = compact_generation_policy(generation_policy)
      historical_comparison = compact_historical_comparison(historical_comparison)
      compact_story_history = compact_historical_story_context(historical_story_context)
      profile_summary = compact_author_profile(post_payload[:author_profile], author_type: author_type)

      context_json = {
        task: "instagram_story_comment_generation",
        output_contract: {
          format: "strict_json",
          count: 8,
          max_chars_per_comment: 140
        },
        profile: profile_summary,
        current_story: {
          image_description: truncate_text(image_description.to_s, max: 280),
          topics: Array(topics).map(&:to_s).reject(&:blank?).uniq.first(10),
          verified_story_facts: verified_story_facts,
          ownership: story_ownership_classification,
          generation_policy: generation_policy
        },
        historical_context: {
          comparison: historical_comparison,
          recent_story_patterns: compact_story_history,
          recent_comments: Array(historical_comments).map { |value| truncate_text(value.to_s, max: 110) }.reject(&:blank?).first(6),
          summary: truncate_text(historical_context.to_s, max: 280)
        }
      }

      <<~PROMPT
        You are a production-grade Instagram engagement assistant.
        Generate concise comments from VERIFIED data only.

        Grounding rules:
        - treat CONTEXT_JSON as the only source of truth
        - never use URLs, IDs, or hidden metadata as evidence
        - do not infer facts not present in `verified_story_facts`
        - if `generation_policy.allow_comment` is false, return empty suggestions
        - if ownership is not `owned_by_profile`, keep output neutral and non-personal
        - if identity_verification.owner_likelihood is low, avoid user-specific assumptions
        - never fabricate OCR text, usernames, objects, scenes, or participants

        Writing rules:
        - natural, public-safe, short comments
        - max 140 chars each
        - vary openings and avoid duplicates
        - avoid explicit/adult language
        - avoid identity, age, gender, or sensitive-trait claims

        Output STRICT JSON only:
        {
          "comment_suggestions": ["...", "...", "...", "...", "...", "...", "...", "..."]
        }

        Generate exactly 8 suggestions, each <= 140 characters.
        Keep at least 3 suggestions neutral-safe for public comments.
        Avoid repeating phrases from previous comments for the same profile.

        CONTEXT_JSON:
        #{JSON.pretty_generate(context_json)}
      PROMPT
    end

    def filter_safe_comments(comments)
      filtered = Array(comments)
      return filtered if BLOCKED_TERMS.empty?

      filtered.reject do |comment|
        lc = comment.to_s.downcase
        BLOCKED_TERMS.any? { |term| lc.include?(term) }
      end
    end

    def normalize_comment(value)
      text = value.to_s.gsub(/\s+/, " ").strip
      return nil if text.blank?

      text.byteslice(0, 140)
    end

    def parse_comment_suggestions(response_payload)
      parsed = JSON.parse(response_payload["response"]) rescue nil
      Array(parsed&.dig("comment_suggestions")).map { |v| normalize_comment(v) }.compact.uniq
    end

    def fallback_comments(image_description:, topics:)
      anchor = Array(topics).map(&:to_s).find(&:present?) || image_description.to_s.split(/[,.]/).first.to_s.downcase
      anchor = "this post" if anchor.blank?

      [
        "Okay this is a whole vibe 🔥",
        "Not gonna lie, this #{anchor} moment is clean 👏",
        "Love the energy on this one ✨",
        "This is low-key so good, great post 🙌",
        "Major main-feed energy right here 😮‍💨",
        "Ate this one, no notes 💯",
        "This made me stop scrolling fr 👀",
        "Super solid post, keep these coming 🚀"
      ]
    end

    def truncate_text(value, max:)
      text = value.to_s.strip
      return text if text.length <= max

      "#{text.byteslice(0, max)}..."
    end

    def compact_local_story_intelligence(payload)
      data = payload.is_a?(Hash) ? payload : {}
      {
        source: data[:source] || data["source"],
        reason: data[:reason] || data["reason"],
        ocr_text: truncate_text(data[:ocr_text] || data["ocr_text"], max: 600),
        transcript: truncate_text(data[:transcript] || data["transcript"], max: 600),
        objects: Array(data[:objects] || data["objects"]).map(&:to_s).reject(&:blank?).first(20),
        scenes: Array(data[:scenes] || data["scenes"]).first(20),
        hashtags: Array(data[:hashtags] || data["hashtags"]).map(&:to_s).reject(&:blank?).first(20),
        mentions: Array(data[:mentions] || data["mentions"]).map(&:to_s).reject(&:blank?).first(20),
        profile_handles: Array(data[:profile_handles] || data["profile_handles"]).map(&:to_s).reject(&:blank?).first(20),
        source_account_reference: (data[:source_account_reference] || data["source_account_reference"]).to_s.presence,
        source_profile_ids: Array(data[:source_profile_ids] || data["source_profile_ids"]).map(&:to_s).reject(&:blank?).first(10),
        media_type: (data[:media_type] || data["media_type"]).to_s.presence,
        face_count: (data[:face_count] || data["face_count"]).to_i,
        people: Array(data[:people] || data["people"]).first(10),
        object_detections: Array(data[:object_detections] || data["object_detections"]).first(25),
        ocr_blocks: Array(data[:ocr_blocks] || data["ocr_blocks"]).first(25)
      }.compact
    end

    def compact_cv_ocr_evidence(payload)
      data = payload.is_a?(Hash) ? payload : {}
      {
        source: data[:source] || data["source"],
        reason: data[:reason] || data["reason"],
        objects: Array(data[:objects] || data["objects"]).map(&:to_s).reject(&:blank?).first(20),
        scenes: Array(data[:scenes] || data["scenes"]).first(20),
        hashtags: Array(data[:hashtags] || data["hashtags"]).map(&:to_s).reject(&:blank?).first(20),
        mentions: Array(data[:mentions] || data["mentions"]).map(&:to_s).reject(&:blank?).first(20),
        profile_handles: Array(data[:profile_handles] || data["profile_handles"]).map(&:to_s).reject(&:blank?).first(20),
        source_account_reference: (data[:source_account_reference] || data["source_account_reference"]).to_s.presence,
        source_profile_ids: Array(data[:source_profile_ids] || data["source_profile_ids"]).map(&:to_s).reject(&:blank?).first(10),
        media_type: (data[:media_type] || data["media_type"]).to_s.presence,
        face_count: (data[:face_count] || data["face_count"]).to_i,
        people: Array(data[:people] || data["people"]).first(10),
        object_detections: Array(data[:object_detections] || data["object_detections"]).first(25),
        ocr_blocks: Array(data[:ocr_blocks] || data["ocr_blocks"]).first(25),
        ocr_text: truncate_text(data[:ocr_text] || data["ocr_text"], max: 600),
        transcript: truncate_text(data[:transcript] || data["transcript"], max: 600)
      }.compact
    end

    def compact_historical_comparison(payload)
      data = payload.is_a?(Hash) ? payload : {}
      {
        shared_topics: Array(data[:shared_topics] || data["shared_topics"]).first(12),
        novel_topics: Array(data[:novel_topics] || data["novel_topics"]).first(12),
        shared_objects: Array(data[:shared_objects] || data["shared_objects"]).first(12),
        novel_objects: Array(data[:novel_objects] || data["novel_objects"]).first(12),
        shared_scenes: Array(data[:shared_scenes] || data["shared_scenes"]).first(12),
        novel_scenes: Array(data[:novel_scenes] || data["novel_scenes"]).first(12),
        recurring_hashtags: Array(data[:recurring_hashtags] || data["recurring_hashtags"]).first(12),
        recurring_mentions: Array(data[:recurring_mentions] || data["recurring_mentions"]).first(12),
        recurring_people_ids: Array(data[:recurring_people_ids] || data["recurring_people_ids"]).first(12),
        has_historical_overlap: ActiveModel::Type::Boolean.new.cast(data[:has_historical_overlap] || data["has_historical_overlap"])
      }
    end

    def compact_verified_story_facts(payload, local_story_intelligence:, cv_ocr_evidence:)
      data = payload.is_a?(Hash) ? payload : {}
      if data.blank?
        data = compact_cv_ocr_evidence(cv_ocr_evidence)
        data[:signal_score] = 0 unless data.key?(:signal_score)
      end

      {
        source: data[:source] || data["source"],
        reason: data[:reason] || data["reason"],
        signal_score: (data[:signal_score] || data["signal_score"]).to_i,
        ocr_text: truncate_text(data[:ocr_text] || data["ocr_text"], max: 320),
        transcript: truncate_text(data[:transcript] || data["transcript"], max: 320),
        objects: Array(data[:objects] || data["objects"]).map(&:to_s).reject(&:blank?).first(15),
        object_detections: compact_object_detections(data[:object_detections] || data["object_detections"]),
        scenes: compact_scenes(data[:scenes] || data["scenes"]),
        hashtags: Array(data[:hashtags] || data["hashtags"]).map(&:to_s).reject(&:blank?).first(15),
        mentions: Array(data[:mentions] || data["mentions"]).map(&:to_s).reject(&:blank?).first(15),
        profile_handles: Array(data[:profile_handles] || data["profile_handles"]).map(&:to_s).reject(&:blank?).first(15),
        detected_usernames: Array(data[:detected_usernames] || data["detected_usernames"]).map(&:to_s).reject(&:blank?).first(15),
        source_profile_references: Array(data[:source_profile_references] || data["source_profile_references"]).map(&:to_s).reject(&:blank?).first(15),
        share_status: (data[:share_status] || data["share_status"]).to_s.presence,
        meme_markers: Array(data[:meme_markers] || data["meme_markers"]).map(&:to_s).reject(&:blank?).first(10),
        face_count: (data[:face_count] || data["face_count"]).to_i,
        faces: compact_faces_payload(data[:faces] || data["faces"]),
        identity_verification: compact_identity_verification(data[:identity_verification] || data["identity_verification"])
      }
    end

    def compact_story_ownership_classification(payload)
      data = payload.is_a?(Hash) ? payload : {}
      {
        label: data[:label] || data["label"],
        decision: data[:decision] || data["decision"],
        confidence: (data[:confidence] || data["confidence"]).to_f,
        summary: truncate_text(data[:summary] || data["summary"], max: 220),
        reason_codes: Array(data[:reason_codes] || data["reason_codes"]).first(10),
        detected_external_usernames: Array(data[:detected_external_usernames] || data["detected_external_usernames"]).first(10),
        source_profile_references: Array(data[:source_profile_references] || data["source_profile_references"]).first(10),
        share_status: data[:share_status] || data["share_status"]
      }
    end

    def compact_generation_policy(payload)
      data = payload.is_a?(Hash) ? payload : {}
      allow_comment_value = if data.key?(:allow_comment)
        data[:allow_comment]
      else
        data["allow_comment"]
      end
      {
        allow_comment: ActiveModel::Type::Boolean.new.cast(allow_comment_value),
        reason_code: data[:reason_code] || data["reason_code"],
        reason: truncate_text(data[:reason] || data["reason"], max: 220),
        classification: data[:classification] || data["classification"],
        signal_score: (data[:signal_score] || data["signal_score"]).to_i,
        historical_overlap: ActiveModel::Type::Boolean.new.cast(data[:historical_overlap] || data["historical_overlap"])
      }
    end

    def compact_historical_story_context(rows)
      cutoff = 45.days.ago
      Array(rows).first(12).filter_map do |row|
        data = row.is_a?(Hash) ? row : {}
        occurred_at = parse_time(data[:occurred_at] || data["occurred_at"])
        next if occurred_at && occurred_at < cutoff

        {
          occurred_at: occurred_at&.iso8601,
          topics: Array(data[:topics] || data["topics"]).first(6),
          objects: Array(data[:objects] || data["objects"]).first(6),
          hashtags: Array(data[:hashtags] || data["hashtags"]).first(6),
          mentions: Array(data[:mentions] || data["mentions"]).first(6),
          profile_handles: Array(data[:profile_handles] || data["profile_handles"]).first(6),
          recurring_people_ids: Array(data[:people] || data["people"]).map { |person| person.is_a?(Hash) ? (person[:person_id] || person["person_id"]) : nil }.compact.first(4),
          face_count: (data[:face_count] || data["face_count"]).to_i
        }
      end.first(6)
    end

    def compact_author_profile(payload, author_type:)
      data = payload.is_a?(Hash) ? payload : {}
      {
        username: data[:username] || data["username"],
        display_name: truncate_text(data[:display_name] || data["display_name"], max: 80),
        author_type: author_type.to_s.presence || "unknown",
        bio_keywords: Array(data[:bio_keywords] || data["bio_keywords"]).map(&:to_s).reject(&:blank?).first(10)
      }
    end

    def compact_identity_verification(payload)
      data = payload.is_a?(Hash) ? payload : {}
      {
        owner_likelihood: data[:owner_likelihood] || data["owner_likelihood"],
        confidence: (data[:confidence] || data["confidence"]).to_f,
        primary_person_present: ActiveModel::Type::Boolean.new.cast(data[:primary_person_present] || data["primary_person_present"]),
        recurring_primary_person: ActiveModel::Type::Boolean.new.cast(data[:recurring_primary_person] || data["recurring_primary_person"]),
        bio_topic_overlap: Array(data[:bio_topic_overlap] || data["bio_topic_overlap"]).first(8),
        age_consistency: data[:age_consistency] || data["age_consistency"],
        gender_consistency: data[:gender_consistency] || data["gender_consistency"],
        reason_codes: Array(data[:reason_codes] || data["reason_codes"]).first(10)
      }
    end

    def compact_faces_payload(payload)
      data = payload.is_a?(Hash) ? payload : {}
      {
        total_count: data[:total_count] || data["total_count"],
        primary_user_count: data[:primary_user_count] || data["primary_user_count"],
        secondary_person_count: data[:secondary_person_count] || data["secondary_person_count"],
        unknown_count: data[:unknown_count] || data["unknown_count"],
        people: Array(data[:people] || data["people"]).map do |row|
          r = row.is_a?(Hash) ? row : {}
          {
            person_id: r[:person_id] || r["person_id"],
            role: r[:role] || r["role"],
            label: r[:label] || r["label"],
            similarity: (r[:similarity] || r["similarity"]).to_f,
            age_range: r[:age_range] || r["age_range"],
            gender: r[:gender] || r["gender"]
          }.compact
        end.first(8)
      }
    end

    def compact_object_detections(rows)
      Array(rows).filter_map do |row|
        data = row.is_a?(Hash) ? row : {}
        label = (data[:label] || data["label"]).to_s.strip
        next if label.blank?

        {
          label: label.downcase,
          confidence: (data[:confidence] || data["confidence"] || data[:score] || data["score"]).to_f.round(3)
        }
      end.uniq.first(8)
    end

    def compact_scenes(rows)
      Array(rows).filter_map do |row|
        data = row.is_a?(Hash) ? row : {}
        scene_type = (data[:type] || data["type"]).to_s.strip
        next if scene_type.blank?

        {
          type: scene_type.downcase,
          timestamp: (data[:timestamp] || data["timestamp"]).to_f.round(2)
        }
      end.uniq.first(8)
    end

    def parse_time(value)
      return nil if value.to_s.blank?

      Time.zone.parse(value.to_s)
    rescue StandardError
      nil
    end
  end
end
