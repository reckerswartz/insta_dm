module Ai
  class CommentRelevanceScorer
    class << self
      MAX_SCORE = 3.0
      MIN_AUTO_POST_SCORE = ENV.fetch("LLM_MIN_AUTO_POST_RELEVANCE_SCORE", "2.0").to_f.clamp(0.5, MAX_SCORE)

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
        ocr_tokens = normalize_tokens(verified_story_facts.to_h["ocr_text"] || verified_story_facts.to_h[:ocr_text])
        transcript_tokens = normalize_tokens(verified_story_facts.to_h["transcript"] || verified_story_facts.to_h[:transcript])

        context_tokens = Array(scored_context.to_h[:prioritized_signals] || scored_context.to_h["prioritized_signals"])
          .first(10)
          .flat_map do |row|
            row.is_a?(Hash) ? normalize_tokens(row[:value] || row["value"]) : normalize_tokens(row.to_s)
          end

        relationship = (
          scored_context.dig(:engagement_memory, :relationship_familiarity) ||
          scored_context.dig("engagement_memory", "relationship_familiarity")
        ).to_s

        visual_context = overlap_ratio(tokens, visual_tokens)
        ocr_context = overlap_ratio(tokens, ocr_tokens)
        transcript_context = overlap_ratio(tokens, transcript_tokens)
        user_context_match = overlap_ratio(tokens, signal_tokens + context_tokens)
        engagement_relevance = engagement_component(relationship: relationship, context_overlap: user_context_match)
        novelty = 1.0 - overlap_ratio(tokens, history_tokens)

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
          length_adjustment
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
            engagement_relevance: factor_payload(engagement_relevance),
            novelty: factor_payload(novelty),
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
            engagement_relevance: factor_payload(0.0),
            novelty: factor_payload(0.0),
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

      def overlap_ratio(tokens, other_tokens)
        return 0.0 if tokens.empty? || other_tokens.empty?

        shared = (tokens & other_tokens).size
        (shared.to_f / tokens.size.to_f).clamp(0.0, 1.0)
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
