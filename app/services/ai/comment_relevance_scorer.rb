module Ai
  class CommentRelevanceScorer
    class << self
      MAX_SCORE = 3.0
      MIN_AUTO_POST_SCORE = ENV.fetch("LLM_MIN_AUTO_POST_RELEVANCE_SCORE", "2.0").to_f.clamp(0.5, MAX_SCORE)
      LOW_CONFIDENCE_ANCHOR_THRESHOLD = 0.55
      HIGH_CONFIDENCE_ANCHOR_THRESHOLD = 0.72
      GENERIC_COMMENT_TOKENS = %w[
        nice
        great
        awesome
        amazing
        beautiful
        lovely
        cool
        vibe
        vibes
        moment
        shot
        post
        frame
        picture
        photo
      ].freeze
      GENERIC_ANCHOR_TOKENS = %w[
        person
        people
        human
        man
        woman
        boy
        girl
        portrait
        selfie
        face
        group
        friends
        family
      ].freeze
      GROUP_HINT_TOKENS = %w[group family friends crowd team everyone].freeze
      TEXT_HEAVY_HINT_TOKENS = %w[loan bank offer promo discount sale apr rate apply ad poster text].freeze
      SINGULAR_PERSON_COMMENT_TOKENS = %w[person man woman boy girl portrait selfie].freeze
      ROBOTIC_PATTERN_PENALTIES = {
        /\(\s*light question\s*\)/i => -0.18,
        /\bintriguing\s+duo\b/i => -0.2,
        /\b[a-z0-9_]+\s+and\s+[a-z0-9_]+,\s+an\s+[a-z0-9_]+\s+duo\b/i => -0.15
      }.freeze

      def rank(suggestions:, image_description:, topics:, historical_comments: [])
        rank_with_breakdown(
          suggestions: suggestions,
          image_description: image_description,
          topics: topics,
          historical_comments: historical_comments
        ).map { |row| [ row[:comment], row[:score] ] }
      end

      def rank_with_breakdown(suggestions:, image_description:, topics:, historical_comments: [], scored_context: {}, verified_story_facts: {})
        rows = Array(suggestions).filter_map do |suggestion|
          text = suggestion.to_s.strip
          next if text.blank?

          breakdown = score_with_breakdown(
            comment: text,
            image_description: image_description,
            topics: topics,
            historical_comments: historical_comments,
            scored_context: scored_context,
            verified_story_facts: verified_story_facts
          )

          {
            comment: text,
            score: breakdown[:score],
            auto_post_eligible: breakdown[:auto_post_eligible],
            confidence_level: breakdown[:confidence_level],
            factors: breakdown[:factors]
          }
        end

        rows.sort_by { |row| -row[:score].to_f }
      end

      def score(comment:, image_description:, topics:, historical_comments: [])
        score_with_breakdown(
          comment: comment,
          image_description: image_description,
          topics: topics,
          historical_comments: historical_comments
        )[:score]
      end

      def score_with_breakdown(comment:, image_description:, topics:, historical_comments: [], scored_context: {}, verified_story_facts: {})
        tokens = normalize_tokens(comment)
        return blank_breakdown if tokens.empty?

        signal_tokens = normalize_tokens(Array(topics).join(" "))
        visual_tokens = normalize_tokens(image_description)
        history_tokens = Array(historical_comments).flat_map { |value| normalize_tokens(value) }
        verified_facts = verified_story_facts.to_h
        ocr_tokens = normalize_tokens(verified_facts["ocr_text"] || verified_facts[:ocr_text])
        transcript_tokens = normalize_tokens(verified_facts["transcript"] || verified_facts[:transcript])
        anchor_weights = confidence_weighted_anchor_map(
          topics: topics,
          verified_story_facts: verified_facts
        )
        specific_anchor_tokens = extract_specific_anchor_tokens(
          image_description: image_description,
          topics: topics,
          verified_story_facts: verified_facts
        )

        context_tokens = Array(scored_context.to_h[:prioritized_signals] || scored_context.to_h["prioritized_signals"])
          .first(10)
          .flat_map do |row|
            row.is_a?(Hash) ? normalize_tokens(row[:value] || row["value"]) : normalize_tokens(row.to_s)
          end

        relationship = (
          scored_context.dig(:engagement_memory, :relationship_familiarity) ||
          scored_context.dig("engagement_memory", "relationship_familiarity")
        ).to_s

        visual_context = weighted_overlap_ratio(
          tokens: tokens,
          anchor_weights: anchor_weights,
          fallback_tokens: visual_tokens
        )
        ocr_context = overlap_ratio(tokens, ocr_tokens)
        transcript_context = overlap_ratio(tokens, transcript_tokens)
        user_context_match = overlap_ratio(tokens, signal_tokens + context_tokens)
        specific_anchor_overlap = overlap_ratio(tokens, specific_anchor_tokens)
        engagement_relevance = engagement_component(relationship: relationship, context_overlap: user_context_match)
        novelty = 1.0 - overlap_ratio(tokens, history_tokens)
        anchor_confidence_penalty = low_confidence_anchor_penalty(tokens: tokens, anchor_weights: anchor_weights)
        fluency_penalty = comment_fluency_penalty(comment)
        generic_comment_penalty = generic_comment_penalty(comment: comment, tokens: tokens, specific_anchor_overlap: specific_anchor_overlap)
        plurality_penalty = plurality_penalty(comment_tokens: tokens, topics: topics, image_description: image_description, verified_story_facts: verified_facts)
        text_mode_penalty = text_mode_penalty(tokens: tokens, ocr_tokens: ocr_tokens, image_description: image_description, topics: topics, verified_story_facts: verified_facts)

        length_adjustment = if comment.length.between?(20, 120)
          0.15
        elsif comment.length > 160
          -0.2
        else
          0.0
        end

        # Keep a non-zero base score so sparse stories can still be reviewed manually.
        score = 0.8 +
          (visual_context * 0.8) +
          (ocr_context * 0.35) +
          (transcript_context * 0.35) +
          (user_context_match * 0.55) +
          (engagement_relevance * 0.35) +
          (novelty * 0.15) +
          length_adjustment +
          anchor_confidence_penalty +
          fluency_penalty +
          generic_comment_penalty +
          plurality_penalty +
          text_mode_penalty
        score = score.clamp(0.0, MAX_SCORE).round(3)

        {
          score: score,
          auto_post_eligible: score >= MIN_AUTO_POST_SCORE,
          confidence_level: confidence_label(score),
          factors: {
            visual_context: factor_payload(visual_context),
            ocr_text: factor_payload(ocr_context),
            transcript: factor_payload(transcript_context),
            user_context_match: factor_payload(user_context_match),
            specific_anchor_overlap: factor_payload(specific_anchor_overlap),
            engagement_relevance: factor_payload(engagement_relevance),
            novelty: factor_payload(novelty),
            anchor_confidence_penalty: penalty_payload(anchor_confidence_penalty),
            fluency_penalty: penalty_payload(fluency_penalty),
            generic_comment_penalty: penalty_payload(generic_comment_penalty),
            plurality_penalty: penalty_payload(plurality_penalty),
            text_mode_penalty: penalty_payload(text_mode_penalty),
            length: {
              value: length_adjustment.round(3),
              label: length_adjustment.positive? ? "good" : (length_adjustment.negative? ? "penalized" : "neutral")
            }
          }
        }
      end

      private

      def blank_breakdown
        {
          score: 0.0,
          auto_post_eligible: false,
          confidence_level: "low",
          factors: {
            visual_context: factor_payload(0.0),
            ocr_text: factor_payload(0.0),
            transcript: factor_payload(0.0),
            user_context_match: factor_payload(0.0),
            specific_anchor_overlap: factor_payload(0.0),
            engagement_relevance: factor_payload(0.0),
            novelty: factor_payload(0.0),
            anchor_confidence_penalty: penalty_payload(0.0),
            fluency_penalty: penalty_payload(0.0),
            generic_comment_penalty: penalty_payload(0.0),
            plurality_penalty: penalty_payload(0.0),
            text_mode_penalty: penalty_payload(0.0),
            length: { value: 0.0, label: "neutral" }
          }
        }
      end

      def engagement_component(relationship:, context_overlap:)
        base = case relationship
        when "familiar" then 0.75
        when "warm" then 0.62
        when "new" then 0.45
        else 0.5
        end
        (base + (context_overlap * 0.35)).clamp(0.0, 1.0)
      end

      def confidence_label(score)
        return "high" if score >= 2.3
        return "medium" if score >= 1.4

        "low"
      end

      def factor_payload(value)
        value = value.to_f.clamp(0.0, 1.0).round(3)
        label =
          if value >= 0.66
            "high"
          elsif value >= 0.33
            "medium"
          else
            "low"
          end
        { value: value, label: label }
      end

      def penalty_payload(value)
        amount = value.to_f.round(3)
        label =
          if amount <= -0.2
            "strong_penalty"
          elsif amount.negative?
            "penalized"
          else
            "neutral"
          end
        { value: amount, label: label }
      end

      def overlap_ratio(tokens, other_tokens)
        return 0.0 if tokens.empty? || other_tokens.empty?

        shared = (tokens & other_tokens).size
        (shared.to_f / tokens.size.to_f).clamp(0.0, 1.0)
      end

      def weighted_overlap_ratio(tokens:, anchor_weights:, fallback_tokens:)
        return 0.0 if tokens.empty?

        weights = anchor_weights.is_a?(Hash) ? anchor_weights : {}
        weighted_overlap = tokens.sum { |token| weights[token].to_f }
        return (weighted_overlap / tokens.size.to_f).clamp(0.0, 1.0) if weighted_overlap.positive?

        overlap_ratio(tokens, fallback_tokens)
      end

      def confidence_weighted_anchor_map(topics:, verified_story_facts:)
        rows = {}
        Array(topics).each do |entry|
          normalize_tokens(entry).each do |token|
            rows[token] = [ rows[token].to_f, 0.5 ].max
          end
        end

        Array(verified_story_facts["objects"] || verified_story_facts[:objects]).each do |entry|
          normalize_tokens(entry).each do |token|
            rows[token] = [ rows[token].to_f, 0.56 ].max
          end
        end

        Array(verified_story_facts["object_detections"] || verified_story_facts[:object_detections]).each do |row|
          next unless row.is_a?(Hash)
          confidence = (row["confidence"] || row[:confidence] || row["score"] || row[:score]).to_f.clamp(0.0, 1.0)
          normalize_tokens(row["label"] || row[:label]).each do |token|
            rows[token] = [ rows[token].to_f, confidence ].max
          end
        end

        rows
      end

      def low_confidence_anchor_penalty(tokens:, anchor_weights:)
        weights = anchor_weights.is_a?(Hash) ? anchor_weights : {}
        matched = tokens.filter_map do |token|
          weight = weights[token]
          next if weight.nil?

          weight.to_f
        end
        return 0.0 if matched.empty?

        low_count = matched.count { |weight| weight < LOW_CONFIDENCE_ANCHOR_THRESHOLD }
        high_count = matched.count { |weight| weight >= HIGH_CONFIDENCE_ANCHOR_THRESHOLD }
        penalty = 0.0
        penalty -= (low_count * 0.06)
        penalty -= 0.12 if high_count.zero? && low_count.positive?
        penalty.clamp(-0.3, 0.0)
      end

      def comment_fluency_penalty(comment)
        text = comment.to_s
        penalty = 0.0
        ROBOTIC_PATTERN_PENALTIES.each do |pattern, amount|
          penalty += amount if text.match?(pattern)
        end
        penalty.clamp(-0.4, 0.0)
      end

      def extract_specific_anchor_tokens(image_description:, topics:, verified_story_facts:)
        tokens = []
        tokens.concat(normalize_tokens(image_description))
        tokens.concat(Array(topics).flat_map { |entry| normalize_tokens(entry) })
        tokens.concat(Array(verified_story_facts["topics"] || verified_story_facts[:topics]).flat_map { |entry| normalize_tokens(entry) })
        tokens.concat(Array(verified_story_facts["objects"] || verified_story_facts[:objects]).flat_map { |entry| normalize_tokens(entry) })
        tokens.concat(Array(verified_story_facts["hashtags"] || verified_story_facts[:hashtags]).flat_map { |entry| normalize_tokens(entry) })
        tokens.concat(Array(verified_story_facts["mentions"] || verified_story_facts[:mentions]).flat_map { |entry| normalize_tokens(entry) })
        tokens.concat(
          Array(verified_story_facts["scenes"] || verified_story_facts[:scenes]).flat_map do |row|
            row.is_a?(Hash) ? normalize_tokens(row["type"] || row[:type]) : normalize_tokens(row)
          end
        )
        tokens.concat(
          Array(verified_story_facts["object_detections"] || verified_story_facts[:object_detections]).flat_map do |row|
            row.is_a?(Hash) ? normalize_tokens(row["label"] || row[:label]) : []
          end
        )

        tokens
          .reject { |token| GENERIC_ANCHOR_TOKENS.include?(token) }
          .uniq
          .first(80)
      end

      def generic_comment_penalty(comment:, tokens:, specific_anchor_overlap:)
        return 0.0 if tokens.empty?

        generic_ratio = tokens.count { |token| GENERIC_COMMENT_TOKENS.include?(token) }.to_f / tokens.size.to_f
        compliment_pattern = /\b(looks great|nice shot|great shot|love this|amazing|beautiful|awesome|nice post)\b/i

        penalty = 0.0
        penalty -= 0.18 if specific_anchor_overlap < 0.08 && generic_ratio >= 0.5
        penalty -= 0.12 if specific_anchor_overlap <= 0.02 && comment.to_s.match?(compliment_pattern)
        penalty.clamp(-0.35, 0.0)
      end

      def plurality_penalty(comment_tokens:, topics:, image_description:, verified_story_facts:)
        face_count = extract_face_count(verified_story_facts)
        group_signals = normalize_tokens(Array(topics).join(" ")) + normalize_tokens(image_description)
        group_context = face_count >= 3 || (group_signals & GROUP_HINT_TOKENS).any?

        singular_person_comment = (comment_tokens & SINGULAR_PERSON_COMMENT_TOKENS).any?
        group_comment = (comment_tokens & GROUP_HINT_TOKENS).any?

        penalty = 0.0
        penalty -= 0.14 if group_context && singular_person_comment && !group_comment
        penalty -= 0.08 if face_count <= 1 && group_comment
        penalty.clamp(-0.22, 0.0)
      end

      def text_mode_penalty(tokens:, ocr_tokens:, image_description:, topics:, verified_story_facts:)
        context_tokens = normalize_tokens(image_description) +
          normalize_tokens(Array(topics).join(" ")) +
          normalize_tokens(Array(verified_story_facts["objects"] || verified_story_facts[:objects]).join(" "))
        text_mode = ocr_tokens.length >= 6 || (context_tokens & TEXT_HEAVY_HINT_TOKENS).size >= 2
        return 0.0 unless text_mode

        combined_text_tokens = (ocr_tokens + TEXT_HEAVY_HINT_TOKENS).uniq
        overlap = overlap_ratio(tokens, combined_text_tokens)
        return 0.0 if overlap >= 0.08

        -0.24
      end

      def extract_face_count(verified_story_facts)
        count = (verified_story_facts["face_count"] || verified_story_facts[:face_count]).to_i
        return count if count.positive?

        faces = verified_story_facts["faces"].is_a?(Hash) ? verified_story_facts["faces"] : (verified_story_facts[:faces].is_a?(Hash) ? verified_story_facts[:faces] : {})
        (faces["total_count"] || faces[:total_count]).to_i
      end

      def normalize_tokens(value)
        value.to_s
          .downcase
          .gsub(/[^a-z0-9\s]/, " ")
          .split
          .reject { |token| token.length < 3 }
          .uniq
      end
    end
  end
end
