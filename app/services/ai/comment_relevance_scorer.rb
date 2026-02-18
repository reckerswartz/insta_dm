module Ai
  class CommentRelevanceScorer
    class << self
      def rank(suggestions:, image_description:, topics:, historical_comments: [])
        rows = Array(suggestions).map do |suggestion|
          text = suggestion.to_s.strip
          next if text.blank?

          [
            text,
            score(
              comment: text,
              image_description: image_description,
              topics: topics,
              historical_comments: historical_comments
            )
          ]
        end.compact

        rows.sort_by { |(_text, value)| -value }
      end

      def score(comment:, image_description:, topics:, historical_comments: [])
        tokens = normalize_tokens(comment)
        return 0.0 if tokens.empty?

        topic_tokens = normalize_tokens(Array(topics).join(" "))
        image_tokens = normalize_tokens(image_description)
        history_tokens = Array(historical_comments).flat_map { |value| normalize_tokens(value) }

        topic_overlap = overlap_ratio(tokens, topic_tokens)
        image_overlap = overlap_ratio(tokens, image_tokens)
        novelty = 1.0 - overlap_ratio(tokens, history_tokens)

        length_bonus = if comment.length.between?(20, 110)
          0.12
        elsif comment.length > 140
          -0.2
        else
          0.0
        end

        raw = (topic_overlap * 0.4) + (image_overlap * 0.25) + (novelty * 0.35) + length_bonus
        raw.clamp(0.0, 1.0).round(4)
      end

      private

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
