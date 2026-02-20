require "json"
require "net/http"

module Ai
  class LocalEngagementCommentGenerator
    DEFAULT_MODEL = "mistral:7b".freeze
    MIN_SUGGESTIONS = 3
    MAX_SUGGESTIONS = 8
    NON_VISUAL_CONTEXT_TOKENS = %w[
      detected
      visual
      signals
      scene
      scenes
      transitions
      inferred
      topics
      story
      media
      context
      extracted
      local
      pipeline
      source
      account
      profile
      generation
      policy
      verified
      facts
      content
    ].freeze
    TRANSIENT_ERRORS = [
      Net::OpenTimeout,
      Net::ReadTimeout,
      Errno::ECONNRESET,
      Errno::ECONNREFUSED
    ].freeze

    def initialize(ollama_client:, model: nil, policy_engine: nil)
      @ollama_client = ollama_client
      @model = model.to_s.presence || DEFAULT_MODEL
      @policy_engine = policy_engine || Ai::CommentPolicyEngine.new
    end

    def generate!(post_payload:, image_description:, topics:, author_type:, channel: "post", historical_comments: [], historical_context: nil, historical_story_context: [], local_story_intelligence: {}, historical_comparison: {}, cv_ocr_evidence: {}, verified_story_facts: {}, story_ownership_classification: {}, generation_policy: {}, profile_preparation: {}, verified_profile_history: [], conversational_voice: {}, scored_context: {}, **_extra)
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
        channel: channel,
        historical_comments: historical_comments,
        historical_context: historical_context,
        historical_story_context: historical_story_context,
        local_story_intelligence: local_story_intelligence,
        historical_comparison: historical_comparison,
        cv_ocr_evidence: cv_ocr_evidence,
        verified_story_facts: verified_story_facts,
        story_ownership_classification: story_ownership_classification,
        generation_policy: generation_policy,
        profile_preparation: profile_preparation,
        verified_profile_history: verified_profile_history,
        conversational_voice: conversational_voice,
        scored_context: scored_context
      )

      resp = @ollama_client.generate(
        model: @model,
        prompt: prompt,
        temperature: 0.7,
        max_tokens: 300
      )

      @last_topics_for_policy = Array(topics).map(&:to_s)
      @last_image_description_for_policy = image_description.to_s
      suggestions = evaluate_suggestions(
        suggestions: parse_comment_suggestions(resp),
        historical_comments: historical_comments,
        scored_context: scored_context
      )
      suggestions = diversify_suggestions(
        suggestions: suggestions,
        topics: topics,
        image_description: image_description,
        channel: channel,
        scored_context: scored_context
      )

      if suggestions.size < MIN_SUGGESTIONS
        retry_resp = @ollama_client.generate(
          model: @model,
          prompt: "#{prompt}\n\nReturn strict JSON only. Ensure 8 non-empty suggestions.",
          temperature: 0.4,
          max_tokens: 220
        )
        retry_suggestions = evaluate_suggestions(
          suggestions: parse_comment_suggestions(retry_resp),
          historical_comments: historical_comments,
          scored_context: scored_context
        )
        retry_suggestions = diversify_suggestions(
          suggestions: retry_suggestions,
          topics: topics,
          image_description: image_description,
          channel: channel,
          scored_context: scored_context
        )
        suggestions = retry_suggestions if retry_suggestions.size >= MIN_SUGGESTIONS
      end

      if suggestions.size < MIN_SUGGESTIONS
        fallback = fallback_comments(
          image_description: image_description,
          topics: topics,
          channel: channel,
          scored_context: scored_context,
          verified_story_facts: verified_story_facts
        ).first(MAX_SUGGESTIONS)
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
        comment_suggestions: fallback_comments(
          image_description: image_description,
          topics: topics,
          channel: channel,
          scored_context: scored_context,
          verified_story_facts: verified_story_facts
        ).first(MAX_SUGGESTIONS)
      }
    end

    private

    def build_prompt(post_payload:, image_description:, topics:, author_type:, channel:, historical_comments:, historical_context:, historical_story_context:, local_story_intelligence:, historical_comparison:, cv_ocr_evidence:, verified_story_facts:, story_ownership_classification:, generation_policy:, profile_preparation: {}, verified_profile_history: [], conversational_voice: {}, scored_context: {})
      tone_profile = Ai::CommentToneProfile.for(channel)
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
      profile_preparation = compact_profile_preparation(profile_preparation)
      verified_profile_history = compact_verified_profile_history(verified_profile_history)
      conversational_voice = compact_conversational_voice(conversational_voice)
      scored_context = compact_scored_context(scored_context)
      occasion_context = build_occasion_context(
        post_payload: post_payload,
        topics: topics,
        image_description: image_description
      )
      tone_plan = build_tone_plan(channel: channel, scored_context: scored_context, occasion_context: occasion_context)
      situational_cues = detect_situational_cues(
        image_description: image_description,
        topics: topics,
        verified_story_facts: verified_story_facts,
        historical_comparison: historical_comparison
      )
      visual_anchors = build_visual_anchors(
        image_description: image_description,
        topics: topics,
        verified_story_facts: verified_story_facts,
        scored_context: scored_context
      )

      context_json = {
        task: "instagram_#{Ai::CommentToneProfile.normalize(channel)}_comment_generation",
        channel: Ai::CommentToneProfile.normalize(channel),
        output_contract: {
          format: "strict_json",
          count: 8,
          max_chars_per_comment: 140
        },
        tone_profile: tone_profile,
        tone_plan: tone_plan,
        occasion_context: occasion_context,
        situational_cues: situational_cues,
        profile: profile_summary,
        profile_preparation: profile_preparation,
        conversational_voice: conversational_voice,
        scored_context: scored_context,
        current_story: {
          image_description: truncate_text(image_description.to_s, max: 280),
          topics: Array(topics).map(&:to_s).reject(&:blank?).uniq.first(10),
          visual_anchors: visual_anchors.first(14),
          verified_story_facts: verified_story_facts,
          ownership: story_ownership_classification,
          generation_policy: generation_policy
        },
        historical_context: {
          comparison: historical_comparison,
          recent_story_patterns: compact_story_history,
          recent_profile_history: verified_profile_history,
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
        - require `profile_preparation.ready_for_comment_generation` to be true for personalized comments
        - if `generation_policy.allow_comment` is false, return empty suggestions
        - if ownership is not `owned_by_profile`, keep output neutral and non-personal
        - if identity_verification.owner_likelihood is low, avoid user-specific assumptions
        - never fabricate OCR text, usernames, objects, scenes, or participants

        Writing rules:
        - channel mode: #{Ai::CommentToneProfile.normalize(channel)}
        - tone guidance: #{tone_profile[:guidance]}
        - follow `tone_plan` and vary style across suggestions
        - use `situational_cues` to tailor tone (for example celebration/travel/lifestyle)
        - adapt to `occasion_context` (weekday/daypart/holiday-like moments)
        - each comment must include at least one phrase grounded in `current_story.visual_anchors` or `current_story.topics`
        - natural, public-safe, short comments
        - max 140 chars each
        - vary openings and avoid duplicates
        - avoid explicit/adult language
        - avoid identity, age, gender, or sensitive-trait claims
        - avoid empty praise with no visual anchor from topics/description
        - reflect recurring themes and wording style from `historical_context` and `conversational_voice`

        Output STRICT JSON only:
        {
          "comment_suggestions": ["...", "...", "...", "...", "...", "...", "...", "..."]
        }

        Generate exactly 8 suggestions, each <= 140 characters.
        Keep at least 3 suggestions neutral-safe for public comments.
        Include 1-2 light conversational questions to invite engagement.
        Avoid repeating phrases from previous comments for the same profile.

        CONTEXT_JSON:
        #{JSON.pretty_generate(context_json)}
      PROMPT
    end

    def evaluate_suggestions(suggestions:, historical_comments:, scored_context: {})
      memory_comments = []
      memory_comments.concat(Array(historical_comments))
      memory_comments.concat(Array(scored_context.dig(:engagement_memory, :recent_generated_comments)))
      memory_comments.concat(Array(scored_context.dig("engagement_memory", "recent_generated_comments")))
      memory_comments.concat(Array(scored_context.dig(:engagement_memory, :recent_story_generated_comments)))
      memory_comments.concat(Array(scored_context.dig("engagement_memory", "recent_story_generated_comments")))

      context_keywords = []
      context_keywords.concat(Array(@last_topics_for_policy))
      context_keywords.concat(extract_keywords_from_text(@last_image_description_for_policy))
      context_keywords.concat(Array(scored_context[:context_keywords] || scored_context["context_keywords"]).map(&:to_s))
      context_keywords.concat(
        Array(scored_context[:prioritized_signals] || scored_context["prioritized_signals"]).first(8).flat_map do |row|
          value = row.is_a?(Hash) ? (row[:value] || row["value"]).to_s : row.to_s
          extract_keywords_from_text(value)
        end
      )
      result = @policy_engine.evaluate(
        suggestions: suggestions,
        historical_comments: memory_comments,
        context_keywords: context_keywords,
        max_suggestions: MAX_SUGGESTIONS
      )
      Array(result[:accepted])
    end

    def diversify_suggestions(suggestions:, topics:, image_description:, channel:, scored_context:)
      rows = Array(suggestions).map { |value| normalize_comment(value) }.compact
      return [] if rows.empty?

      selected = []
      used_openers = Array(scored_context.dig(:engagement_memory, :recent_openers)) +
        Array(scored_context.dig("engagement_memory", "recent_openers"))
      used_openers = used_openers.map(&:to_s)

      buckets = rows.group_by { |text| tone_bucket(text) }
      order = %w[observational supportive playful celebratory curious]

      loop do
        added = false
        order.each do |bucket|
          candidate = Array(buckets[bucket]).find do |text|
            !selected.include?(text) &&
              !used_openers.include?(opening_signature(text)) &&
              !too_similar_to_selected?(text, selected)
          end
          next unless candidate

          selected << candidate
          used_openers << opening_signature(candidate)
          added = true
          break if selected.size >= MAX_SUGGESTIONS
        end
        break if selected.size >= MAX_SUGGESTIONS || !added
      end

      if selected.none? { |row| row.include?("?") }
        question = build_light_question(topics: topics, image_description: image_description, channel: channel)
        selected << question if question.present?
      end

      selected.uniq.first(MAX_SUGGESTIONS)
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

    def fallback_comments(image_description:, topics:, channel:, scored_context:, verified_story_facts:)
      anchors = build_visual_anchors(
        image_description: image_description,
        topics: topics,
        verified_story_facts: verified_story_facts,
        scored_context: scored_context
      )
      anchor = anchors.first.to_s.presence || "this moment"

      if Ai::CommentToneProfile.normalize(channel) == "story"
        [
          "#{anchor.capitalize} looks great here.",
          "Love how you framed the #{anchor}.",
          "The #{anchor} detail really stands out.",
          "This #{anchor} shot feels super natural.",
          "Great capture of the #{anchor}.",
          "What made you choose this #{anchor} moment?",
          "Strong story frame around the #{anchor}.",
          "The #{anchor} adds a nice touch."
        ]
      else
        [
          "Great focus on the #{anchor}.",
          "The #{anchor} detail lands really well.",
          "Love the way the #{anchor} is framed.",
          "Clean composition with the #{anchor}.",
          "The #{anchor} gives this post personality.",
          "What inspired this #{anchor} setup?",
          "Nice balance and strong #{anchor} context.",
          "The #{anchor} makes this feel more real."
        ]
      end
    end

    def detect_situational_cues(image_description:, topics:, verified_story_facts:, historical_comparison:)
      tokens = []
      tokens.concat(Array(topics).map(&:to_s))
      tokens.concat(Array(verified_story_facts[:topics] || verified_story_facts["topics"]).map(&:to_s))
      tokens.concat(Array(verified_story_facts[:hashtags] || verified_story_facts["hashtags"]).map(&:to_s))
      tokens.concat(Array(historical_comparison[:novel_topics] || historical_comparison["novel_topics"]).map(&:to_s))
      tokens.concat(extract_keywords_from_text(image_description.to_s))
      corpus = tokens.join(" ").downcase

      cues = []
      cues << "celebration" if corpus.match?(/\b(birthday|party|wedding|anniversary|celebrat|congrats|graduation)\b/)
      cues << "travel" if corpus.match?(/\b(travel|trip|vacation|beach|airport|hotel|flight|mountain|city)\b/)
      cues << "lifestyle" if corpus.match?(/\b(workout|gym|coffee|food|restaurant|fashion|outfit|selfcare|morning)\b/)
      cues << "social" if corpus.match?(/\b(friend|family|hangout|crew|together|date)\b/)
      cues << "creative" if corpus.match?(/\b(art|music|dance|shoot|photo|film|design)\b/)
      cues = [ "general" ] if cues.empty?
      cues.uniq.first(4)
    end

    def build_occasion_context(post_payload:, topics:, image_description:)
      post = post_payload.is_a?(Hash) ? (post_payload[:post] || post_payload["post"]) : {}
      timestamp = parse_time(post[:taken_at] || post["taken_at"] || post[:occurred_at] || post["occurred_at"]) || Time.current
      month_day = timestamp.strftime("%m-%d")
      text_blob = "#{Array(topics).join(' ')} #{image_description}".downcase

      holiday = case month_day
      when "12-25" then "christmas"
      when "01-01" then "new_year"
      when "07-04" then "independence_day"
      when "10-31" then "halloween"
      when "02-14" then "valentines_day"
      else
        nil
      end

      inferred_event =
        if text_blob.match?(/\b(birthday|anniversary|graduation|wedding|party)\b/)
          "milestone"
        elsif text_blob.match?(/\b(travel|trip|vacation|airport|hotel)\b/)
          "travel"
        elsif text_blob.match?(/\b(festival|concert|game|match)\b/)
          "event"
        end

      {
        weekday: timestamp.strftime("%A").downcase,
        daypart: daypart_for(timestamp),
        month: timestamp.strftime("%B").downcase,
        holiday_hint: holiday,
        inferred_event: inferred_event
      }.compact
    end

    def build_tone_plan(channel:, scored_context:, occasion_context:)
      relationship = scored_context.dig(:engagement_memory, :relationship_familiarity) ||
        scored_context.dig("engagement_memory", "relationship_familiarity") || "neutral"
      daypart = occasion_context[:daypart].to_s
      event = occasion_context[:inferred_event].to_s

      styles = %w[observational supportive playful curious celebratory]
      styles.delete("playful") if relationship == "professional"
      styles.unshift("celebratory") if event == "milestone"
      styles.unshift("observational") if daypart == "morning"
      styles.unshift("supportive") if channel.to_s == "story"

      {
        relationship_familiarity: relationship,
        preferred_style_order: styles.uniq.first(5),
        include_light_question: true
      }
    end

    def extract_keywords_from_text(text)
      text.to_s.downcase.scan(/[a-z0-9]+/)
        .reject { |token| token.length < 4 }
        .reject { |token| NON_VISUAL_CONTEXT_TOKENS.include?(token) }
        .uniq
        .first(24)
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

    def compact_profile_preparation(payload)
      data = payload.is_a?(Hash) ? payload : {}
      identity = data[:identity_consistency].is_a?(Hash) ? data[:identity_consistency] : (data["identity_consistency"].is_a?(Hash) ? data["identity_consistency"] : {})
      analysis = data[:analysis].is_a?(Hash) ? data[:analysis] : (data["analysis"].is_a?(Hash) ? data["analysis"] : {})

      {
        ready_for_comment_generation: ActiveModel::Type::Boolean.new.cast(data[:ready_for_comment_generation] || data["ready_for_comment_generation"]),
        reason_code: data[:reason_code] || data["reason_code"],
        reason: truncate_text(data[:reason] || data["reason"], max: 220),
        prepared_at: data[:prepared_at] || data["prepared_at"],
        analyzed_posts_count: (analysis[:analyzed_posts_count] || analysis["analyzed_posts_count"]).to_i,
        posts_with_structured_signals_count: (analysis[:posts_with_structured_signals_count] || analysis["posts_with_structured_signals_count"]).to_i,
        latest_posts_analyzed: ActiveModel::Type::Boolean.new.cast(analysis[:latest_posts_analyzed] || analysis["latest_posts_analyzed"]),
        identity_consistency: {
          consistent: ActiveModel::Type::Boolean.new.cast(identity[:consistent] || identity["consistent"]),
          reason_code: identity[:reason_code] || identity["reason_code"],
          dominance_ratio: (identity[:dominance_ratio] || identity["dominance_ratio"]).to_f,
          appearance_count: (identity[:appearance_count] || identity["appearance_count"]).to_i,
          total_faces: (identity[:total_faces] || identity["total_faces"]).to_i
        }
      }
    end

    def compact_verified_profile_history(rows)
      Array(rows).first(10).map do |row|
        data = row.is_a?(Hash) ? row : {}
        {
          shortcode: data[:shortcode] || data["shortcode"],
          taken_at: data[:taken_at] || data["taken_at"],
          topics: Array(data[:topics] || data["topics"]).first(6),
          objects: Array(data[:objects] || data["objects"]).first(6),
          hashtags: Array(data[:hashtags] || data["hashtags"]).first(6),
          mentions: Array(data[:mentions] || data["mentions"]).first(6),
          face_count: (data[:face_count] || data["face_count"]).to_i,
          primary_face_count: (data[:primary_face_count] || data["primary_face_count"]).to_i,
          secondary_face_count: (data[:secondary_face_count] || data["secondary_face_count"]).to_i,
          image_description: truncate_text(data[:image_description] || data["image_description"], max: 180)
        }
      end
    end

    def compact_conversational_voice(payload)
      data = payload.is_a?(Hash) ? payload : {}
      {
        author_type: data[:author_type] || data["author_type"],
        profile_tags: Array(data[:profile_tags] || data["profile_tags"]).first(10),
        bio_keywords: Array(data[:bio_keywords] || data["bio_keywords"]).first(10),
        recurring_topics: Array(data[:recurring_topics] || data["recurring_topics"]).first(12),
        recurring_hashtags: Array(data[:recurring_hashtags] || data["recurring_hashtags"]).first(10),
        frequent_people_labels: Array(data[:frequent_people_labels] || data["frequent_people_labels"]).first(8),
        prior_comment_examples: Array(data[:prior_comment_examples] || data["prior_comment_examples"]).map { |value| truncate_text(value, max: 100) }.first(6)
      }.compact
    end

    def compact_scored_context(payload)
      data = payload.is_a?(Hash) ? payload : {}
      {
        prioritized_signals: Array(data[:prioritized_signals] || data["prioritized_signals"]).first(12).map do |row|
          next unless row.is_a?(Hash)

          {
            value: (row[:value] || row["value"]).to_s,
            signal_type: (row[:signal_type] || row["signal_type"]).to_s,
            source: (row[:source] || row["source"]).to_s,
            score: (row[:score] || row["score"]).to_f.round(3)
          }
        end.compact,
        style_profile: (data[:style_profile] || data["style_profile"]).is_a?(Hash) ? (data[:style_profile] || data["style_profile"]) : {},
        engagement_memory: (data[:engagement_memory] || data["engagement_memory"]).is_a?(Hash) ? (data[:engagement_memory] || data["engagement_memory"]) : {},
        context_keywords: Array(data[:context_keywords] || data["context_keywords"]).map(&:to_s).reject(&:blank?).first(24)
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

    def daypart_for(timestamp)
      hour = timestamp.hour
      return "morning" if hour < 12
      return "afternoon" if hour < 17
      return "evening" if hour < 21

      "night"
    end

    def tone_bucket(text)
      body = text.to_s.downcase
      return "curious" if body.include?("?")
      return "celebratory" if body.match?(/\b(congrats|celebrate|huge|big win|so proud)\b/)
      return "playful" if body.match?(/\b(low-key|fr|vibe|mood|iconic)\b/)
      return "supportive" if body.match?(/\b(love|solid|great|nice|clean)\b/)

      "observational"
    end

    def opening_signature(comment)
      comment.to_s.downcase.scan(/[a-z0-9]+/).first(3).join(" ")
    end

    def too_similar_to_selected?(candidate, selected)
      tokens = candidate.to_s.downcase.scan(/[a-z0-9]+/).uniq
      return false if tokens.empty?

      Array(selected).any? do |row|
        compare = row.to_s.downcase.scan(/[a-z0-9]+/).uniq
        next false if compare.empty?

        intersection = (tokens & compare).length
        union = (tokens | compare).length
        next false if union.zero?

        (intersection.to_f / union.to_f) >= 0.74
      end
    end

    def build_light_question(topics:, image_description:, channel:)
      anchor = Array(topics).map(&:to_s).find(&:present?) || extract_keywords_from_text(image_description.to_s).first
      return nil if anchor.blank?

      if Ai::CommentToneProfile.normalize(channel) == "story"
        "What made this #{anchor} moment stand out most for you?"
      else
        "What inspired this #{anchor} setup?"
      end
    end

    def build_visual_anchors(image_description:, topics:, verified_story_facts:, scored_context:)
      facts = verified_story_facts.is_a?(Hash) ? verified_story_facts : {}
      anchors = []
      anchors.concat(Array(topics).map(&:to_s))
      anchors.concat(Array(facts[:topics] || facts["topics"]).map(&:to_s))
      anchors.concat(Array(facts[:objects] || facts["objects"]).map(&:to_s))
      anchors.concat(Array(facts[:hashtags] || facts["hashtags"]).map(&:to_s))
      anchors.concat(Array(facts[:mentions] || facts["mentions"]).map(&:to_s))
      anchors.concat(Array(facts[:profile_handles] || facts["profile_handles"]).map(&:to_s))
      anchors.concat(
        Array(facts[:object_detections] || facts["object_detections"]).map do |row|
          row.is_a?(Hash) ? (row[:label] || row["label"]).to_s : ""
        end
      )
      anchors.concat(
        Array(scored_context[:prioritized_signals] || scored_context["prioritized_signals"]).map do |row|
          row.is_a?(Hash) ? (row[:value] || row["value"]).to_s : row.to_s
        end
      )
      anchors.concat(extract_keywords_from_text(image_description.to_s))

      anchors
        .map { |value| normalize_anchor(value) }
        .reject(&:blank?)
        .uniq
        .first(18)
    end

    def normalize_anchor(value)
      text = value.to_s.downcase.strip
      return nil if text.blank?

      cleaned = text.gsub(/[^a-z0-9#@_\-\s]/, " ").gsub(/\s+/, " ").strip
      return nil if cleaned.blank?

      tokens = cleaned.scan(/[a-z0-9#@_\-]+/)
      return nil if tokens.empty?
      return nil if tokens.all? { |token| NON_VISUAL_CONTEXT_TOKENS.include?(token) }

      tokens.join(" ").byteslice(0, 36)
    end
  end
end
