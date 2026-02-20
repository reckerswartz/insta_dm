# frozen_string_literal: true

module Ai
  module PostCommentGeneration
    class SignalContext
      def initialize(analysis:, metadata:, max_suggestions:)
        @analysis = normalize_hash(analysis)
        @metadata = normalize_hash(metadata)
        @max_suggestions = max_suggestions.to_i
      end

      def face_count
        summary_face_count = analysis.dig("face_summary", "face_count").to_i
        return summary_face_count if summary_face_count.positive?

        metadata.dig("face_recognition", "face_count").to_i
      end

      def ocr_text
        analysis["ocr_text"].to_s.strip.presence ||
          analysis["video_ocr_text"].to_s.strip.presence ||
          metadata.dig("ocr_analysis", "ocr_text").to_s.strip.presence ||
          metadata.dig("video_processing", "ocr_text").to_s.strip.presence
      end

      def transcript
        analysis["transcript"].to_s.strip.presence ||
          metadata.dig("video_processing", "transcript").to_s.strip.presence
      end

      def text_context
        [ ocr_text, transcript ]
          .map(&:to_s)
          .map(&:strip)
          .reject(&:blank?)
          .join("\n")
          .presence
      end

      def missing_required_signals
        missing = []
        missing << "face" unless face_count.positive?
        missing << "text_context" if text_context.blank?
        missing
      end

      def topics
        normalized_topics(
          normalized_topics(analysis["topics"]) +
          normalized_topics(analysis["video_topics"]) +
          normalized_topics(analysis["video_objects"]) +
          normalized_topics(analysis["video_hashtags"]) +
          normalized_topics(metadata.dig("video_processing", "topics")) +
          normalized_topics(metadata.dig("video_processing", "objects")) +
          normalized_topics(metadata.dig("video_processing", "hashtags"))
        )
      end

      def image_description
        description = analysis["image_description"].to_s.strip
        if description.blank? && topics.any?
          description = "Detected visual signals: #{topics.first(6).join(', ')}."
        end

        video_summary = analysis["video_context_summary"].to_s.strip.presence || metadata.dig("video_processing", "context_summary").to_s.strip.presence
        if description.present? && video_summary.present?
          description = "#{description} #{video_summary}".strip
        elsif description.blank? && video_summary.present?
          description = video_summary
        end

        if transcript.to_s.present?
          transcript_excerpt = transcript.to_s.gsub(/\s+/, " ").strip.byteslice(0, 220)
          description = [ description, "Audio transcript: #{transcript_excerpt}." ].compact.join(" ").strip
        end

        description.presence
      end

      def cv_ocr_evidence
        {
          source: "post_analysis",
          media_type: analysis["video_semantic_route"].to_s.presence || metadata.dig("video_processing", "semantic_route").to_s.presence || "image",
          objects: topics.first(20),
          hashtags: normalized_topics(analysis["hashtags"]).first(20),
          mentions: normalized_topics(analysis["mentions"]).first(20),
          profile_handles: normalized_topics(analysis["video_profile_handles"]).first(20),
          scenes: Array(analysis["video_scenes"]).select { |row| row.is_a?(Hash) }.first(20),
          ocr_text: ocr_text.to_s.presence,
          transcript: transcript.to_s.presence
        }.compact
      end

      def normalize_suggestions(value)
        Array(value).filter_map do |raw|
          text = raw.to_s.gsub(/\s+/, " ").strip
          next if text.blank?

          text.byteslice(0, 140)
        end.uniq.first(max_suggestions)
      end

      private

      attr_reader :analysis, :metadata, :max_suggestions

      def normalize_hash(value)
        value.is_a?(Hash) ? value.deep_dup : {}
      end

      def normalized_topics(value)
        Array(value).map(&:to_s).map(&:strip).reject(&:blank?).uniq
      end
    end
  end
end
