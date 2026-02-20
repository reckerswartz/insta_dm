module Ai
  class PostCommentGenerationService
    REQUIRED_SIGNAL_KEYS = %w[face text_context].freeze
    MAX_SUGGESTIONS = 8

    def initialize(
      account:,
      profile:,
      post:,
      preparation_summary: nil,
      profile_preparation_service: nil,
      comment_generator: nil,
      enforce_required_evidence: true
    )
      @account = account
      @profile = profile
      @post = post
      @preparation_summary = preparation_summary
      @profile_preparation_service = profile_preparation_service
      @comment_generator = comment_generator
      @enforce_required_evidence = ActiveModel::Type::Boolean.new.cast(enforce_required_evidence)
    end

    def run!
      return skipped_result(reason_code: "post_missing") unless post&.persisted?

      analysis = normalized_hash(post.analysis)
      metadata = normalized_hash(post.metadata)
      preparation = prepared_history_summary

      face_count = extract_face_count(analysis: analysis, metadata: metadata)
      ocr_text = extract_ocr_text(analysis: analysis, metadata: metadata)
      transcript = extract_transcript(analysis: analysis, metadata: metadata)
      text_context = extract_text_context(analysis: analysis, metadata: metadata)
      history_ready = ActiveModel::Type::Boolean.new.cast(preparation["ready_for_comment_generation"])

      missing_required = []
      missing_required << "face" unless face_count.positive?
      missing_required << "text_context" if text_context.blank?
      history_pending = !history_ready
      missing_signals = missing_required.dup
      missing_signals << "history" if history_pending

      if missing_required.any? && enforce_required_evidence?
        return persist_blocked!(
          analysis: analysis,
          metadata: metadata,
          preparation: preparation,
          missing_signals: missing_signals,
          reason_code: "missing_required_evidence"
        )
      end

      topics = merged_topics(analysis: analysis, metadata: metadata)
      image_description = build_image_description(
        analysis: analysis,
        metadata: metadata,
        topics: topics,
        transcript: transcript
      )

      if image_description.blank?
        return persist_blocked!(
          analysis: analysis,
          metadata: metadata,
          preparation: preparation,
          missing_signals: [ "visual_context" ],
          reason_code: "missing_visual_context"
        )
      end

      result = comment_generator.generate!(
        post_payload: post_payload,
        image_description: image_description,
        topics: topics,
        author_type: inferred_author_type,
        historical_comments: historical_comments,
        historical_context: historical_context,
        profile_preparation: preparation,
        verified_profile_history: verified_profile_history,
        conversational_voice: conversational_voice,
        cv_ocr_evidence: build_comment_context_payload(
          analysis: analysis,
          metadata: metadata,
          topics: topics,
          transcript: transcript,
          ocr_text: ocr_text
        )
      )

      suggestions = normalize_suggestions(result[:comment_suggestions])
      if suggestions.empty?
        return persist_blocked!(
          analysis: analysis,
          metadata: metadata,
          preparation: preparation,
          missing_signals: [ "generation_output" ],
          reason_code: "comment_generation_empty",
          error_message: result[:error_message].to_s.presence || "Comment generation produced no valid suggestions."
        )
      end

      analysis["comment_suggestions"] = suggestions
      analysis["comment_generation_status"] = result[:status].to_s.presence || "ok"
      analysis["comment_generation_source"] = result[:source].to_s.presence || "ollama"
      analysis["comment_generation_fallback_used"] = ActiveModel::Type::Boolean.new.cast(result[:fallback_used])
      analysis["comment_generation_error"] = result[:error_message].to_s.presence

      metadata["comment_generation_policy"] = {
        "status" => policy_status(missing_required: missing_required, history_pending: history_pending),
        "required_signals" => REQUIRED_SIGNAL_KEYS,
        "missing_signals" => missing_signals,
        "enforce_required_evidence" => enforce_required_evidence?,
        "history_ready" => history_ready,
        "history_reason_code" => preparation["reason_code"].to_s.presence,
        "face_count" => face_count,
        "text_context_present" => text_context.present?,
        "ocr_text_present" => ocr_text.present?,
        "transcript_present" => transcript.present?,
        "updated_at" => Time.current.iso8601(3)
      }.compact

      post.update!(analysis: analysis, metadata: metadata)

      {
        blocked: false,
        status: analysis["comment_generation_status"],
        source: analysis["comment_generation_source"],
        suggestions_count: suggestions.length,
        reason_code: nil,
        history_reason_code: preparation["reason_code"].to_s.presence
      }
    rescue StandardError => e
      analysis = normalized_hash(post&.analysis)
      metadata = normalized_hash(post&.metadata)
      persist_blocked!(
        analysis: analysis,
        metadata: metadata,
        preparation: prepared_history_summary,
        missing_signals: [ "generation_error" ],
        reason_code: "comment_generation_error",
        error_message: "#{e.class}: #{e.message}"
      )
    end

    private

    attr_reader :account, :profile, :post

    def prepared_history_summary
      return @prepared_history_summary if defined?(@prepared_history_summary)

      @prepared_history_summary =
        if @preparation_summary.is_a?(Hash)
          @preparation_summary
        else
          service =
            @profile_preparation_service ||
            Ai::ProfileCommentPreparationService.new(
              account: account,
              profile: profile,
              analyze_missing_posts: false
            )
          service.prepare!(force: false)
        end
    rescue StandardError => e
      {
        "ready_for_comment_generation" => false,
        "reason_code" => "profile_preparation_failed",
        "reason" => e.message.to_s,
        "error_class" => e.class.name
      }
    end

    def comment_generator
      @comment_generator ||=
        Ai::LocalEngagementCommentGenerator.new(
          ollama_client: Ai::OllamaClient.new,
          model: preferred_model
        )
    end

    def preferred_model
      row = profile&.latest_analysis&.ai_provider_setting
      row&.config_value("ollama_model").to_s.presence || "mistral:7b"
    rescue StandardError
      "mistral:7b"
    end

    def post_payload
      builder = Ai::PostAnalysisContextBuilder.new(profile: profile, post: post)
      payload = builder.payload
      payload[:rules] = (payload[:rules].is_a?(Hash) ? payload[:rules] : {}).merge(
        require_history_context: false,
        require_face_signal: true,
        require_ocr_signal: true,
        require_text_context: true
      )
      payload
    rescue StandardError
      {}
    end

    def inferred_author_type
      tags = profile.profile_tags.pluck(:name).map(&:to_s)
      return "relative" if tags.include?("relative")
      return "friend" if tags.include?("friend") || tags.include?("female_friend") || tags.include?("male_friend")
      return "page" if tags.include?("page")
      return "personal_user" if tags.include?("personal_user")

      "unknown"
    rescue StandardError
      "unknown"
    end

    def historical_comments
      rows = profile.instagram_profile_events.where(kind: "post_comment_sent").order(detected_at: :desc, id: :desc).limit(20).pluck(:metadata)
      out = rows.filter_map do |meta|
        row = meta.is_a?(Hash) ? meta : {}
        row["comment_text"].to_s.strip.presence
      end
      out.uniq.first(12)
    rescue StandardError
      []
    end

    def historical_context
      profile.history_narrative_text(max_chunks: 4).to_s
    rescue StandardError
      ""
    end

    def verified_profile_history
      rows = profile.instagram_profile_posts
        .where(ai_status: "analyzed")
        .where.not(id: post.id)
        .includes(:instagram_post_faces)
        .recent_first
        .limit(8)

      rows.map do |row|
        analysis = normalized_hash(row.analysis)
        {
          shortcode: row.shortcode.to_s,
          taken_at: row.taken_at&.iso8601,
          topics: normalized_topics(analysis["topics"]).first(8),
          objects: normalized_topics(analysis["objects"]).first(8),
          hashtags: normalized_topics(analysis["hashtags"]).first(8),
          mentions: normalized_topics(analysis["mentions"]).first(8),
          face_count: row.instagram_post_faces.size,
          image_description: analysis["image_description"].to_s.byteslice(0, 220)
        }
      end
    rescue StandardError
      []
    end

    def conversational_voice
      summary = profile.instagram_profile_behavior_profile&.behavioral_summary
      summary = {} unless summary.is_a?(Hash)

      {
        profile_tags: profile.profile_tags.pluck(:name).map(&:to_s).uniq.first(10),
        recurring_topics: hash_keys(summary["topic_clusters"]),
        recurring_hashtags: hash_keys(summary["top_hashtags"]),
        frequent_people_labels: frequent_people_labels(summary["frequent_secondary_persons"])
      }
    rescue StandardError
      {}
    end

    def hash_keys(value)
      return [] unless value.is_a?(Hash)

      value.keys.map(&:to_s).map(&:strip).reject(&:blank?).first(10)
    end

    def frequent_people_labels(value)
      Array(value).filter_map do |row|
        next unless row.is_a?(Hash)

        row["label"].to_s.presence || row[:label].to_s.presence
      end.map(&:to_s).map(&:strip).reject(&:blank?).uniq.first(8)
    end

    def normalized_topics(value)
      Array(value).map(&:to_s).map(&:strip).reject(&:blank?).uniq
    end

    def merged_topics(analysis:, metadata:)
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

    def normalize_suggestions(value)
      Array(value).filter_map do |raw|
        text = raw.to_s.gsub(/\s+/, " ").strip
        next if text.blank?

        text.byteslice(0, 140)
      end.uniq.first(MAX_SUGGESTIONS)
    end

    def extract_face_count(analysis:, metadata:)
      summary_face_count = analysis.dig("face_summary", "face_count").to_i
      return summary_face_count if summary_face_count.positive?

      metadata.dig("face_recognition", "face_count").to_i
    end

    def extract_ocr_text(analysis:, metadata:)
      analysis["ocr_text"].to_s.strip.presence ||
        analysis["video_ocr_text"].to_s.strip.presence ||
        metadata.dig("ocr_analysis", "ocr_text").to_s.strip.presence ||
        metadata.dig("video_processing", "ocr_text").to_s.strip.presence
    end

    def extract_transcript(analysis:, metadata:)
      analysis["transcript"].to_s.strip.presence ||
        metadata.dig("video_processing", "transcript").to_s.strip.presence
    end

    def extract_text_context(analysis:, metadata:)
      [ extract_ocr_text(analysis: analysis, metadata: metadata), extract_transcript(analysis: analysis, metadata: metadata) ]
        .map(&:to_s)
        .map(&:strip)
        .reject(&:blank?)
        .join("\n")
        .presence
    end

    def build_image_description(analysis:, metadata:, topics:, transcript:)
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
        snippet = "Audio transcript: #{transcript_excerpt}."
        description = [ description, snippet ].compact.join(" ").strip
      end

      description.presence
    end

    def build_comment_context_payload(analysis:, metadata:, topics:, transcript:, ocr_text:)
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

    def persist_blocked!(analysis:, metadata:, preparation:, missing_signals:, reason_code:, error_message: nil)
      analysis = normalized_hash(analysis)
      metadata = normalized_hash(metadata)

      missing = Array(missing_signals).map(&:to_s).map(&:strip).reject(&:blank?).uniq
      reason = blocked_reason(preparation: preparation, missing_signals: missing, fallback_reason_code: reason_code)

      analysis["comment_suggestions"] = []
      analysis["comment_generation_status"] = "blocked_missing_required_evidence"
      analysis["comment_generation_source"] = "policy"
      analysis["comment_generation_fallback_used"] = false
      analysis["comment_generation_error"] = error_message.to_s.presence || reason

      metadata["comment_generation_policy"] = {
        "status" => "blocked",
        "required_signals" => REQUIRED_SIGNAL_KEYS,
        "missing_signals" => missing,
        "enforce_required_evidence" => enforce_required_evidence?,
        "history_ready" => ActiveModel::Type::Boolean.new.cast(preparation["ready_for_comment_generation"]),
        "history_reason_code" => preparation["reason_code"].to_s.presence,
        "history_reason" => preparation["reason"].to_s.presence,
        "blocked_reason_code" => reason_code.to_s.presence || "missing_required_evidence",
        "blocked_reason" => reason,
        "updated_at" => Time.current.iso8601(3)
      }.compact

      post.update!(analysis: analysis, metadata: metadata) if post&.persisted?

      {
        blocked: true,
        status: analysis["comment_generation_status"],
        source: analysis["comment_generation_source"],
        suggestions_count: 0,
        reason_code: reason_code.to_s.presence || "missing_required_evidence",
        history_reason_code: preparation["reason_code"].to_s.presence
      }
    end

    def blocked_reason(preparation:, missing_signals:, fallback_reason_code:)
      parts = []
      parts << "face_signal_missing" if missing_signals.include?("face")
      parts << "text_context_missing(ocr_or_transcript)" if missing_signals.include?("text_context")
      parts << fallback_reason_code.to_s if parts.empty?
      parts.join(", ")
    end

    def policy_status(missing_required:, history_pending:)
      return "enabled_with_missing_required_evidence" if missing_required.any?
      return "enabled_history_pending" if history_pending

      "enabled"
    end

    def skipped_result(reason_code:)
      {
        blocked: true,
        status: "skipped",
        source: "policy",
        suggestions_count: 0,
        reason_code: reason_code.to_s,
        history_reason_code: nil
      }
    end

    def normalized_hash(value)
      value.is_a?(Hash) ? value.deep_dup : {}
    end

    def enforce_required_evidence?
      @enforce_required_evidence
    end
  end
end
