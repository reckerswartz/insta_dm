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
      return policy_persistence.skipped_result(reason_code: "post_missing") unless post&.persisted?

      analysis = normalized_hash(post.analysis)
      metadata = normalized_hash(post.metadata)
      Ai::ProfileInsightStore.new.ingest_post!(
        profile: profile,
        post: post,
        analysis: analysis,
        metadata: metadata
      )
      preparation = prepared_history_summary
      signals = signal_context(analysis: analysis, metadata: metadata)
      scored_context = build_scored_context(analysis: analysis)

      face_count = signals.face_count
      ocr_text = signals.ocr_text
      transcript = signals.transcript
      text_context = signals.text_context
      history_ready = ActiveModel::Type::Boolean.new.cast(preparation["ready_for_comment_generation"])
      missing_required = signals.missing_required_signals
      history_pending = !history_ready
      missing_signals = missing_required.dup
      missing_signals << "history" if history_pending

      if missing_required.any? && enforce_required_evidence?
        return policy_persistence.persist_blocked!(
          analysis: analysis,
          metadata: metadata,
          preparation: preparation,
          missing_signals: missing_signals,
          reason_code: "missing_required_evidence"
        )
      end

      topics = signals.topics
      image_description = signals.image_description

      if image_description.blank?
        return policy_persistence.persist_blocked!(
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
        channel: "post",
        historical_comments: historical_comments,
        historical_context: historical_context,
        profile_preparation: preparation,
        verified_profile_history: verified_profile_history,
        conversational_voice: conversational_voice,
        cv_ocr_evidence: signals.cv_ocr_evidence,
        scored_context: scored_context
      )

      suggestions = signals.normalize_suggestions(result[:comment_suggestions])
      if suggestions.empty?
        return policy_persistence.persist_blocked!(
          analysis: analysis,
          metadata: metadata,
          preparation: preparation,
          missing_signals: [ "generation_output" ],
          reason_code: "comment_generation_empty",
          error_message: result[:error_message].to_s.presence || "Comment generation produced no valid suggestions."
        )
      end

      policy_persistence.persist_success!(
        analysis: analysis,
        metadata: metadata,
        preparation: preparation,
        missing_required: missing_required,
        missing_signals: missing_signals,
        face_count: face_count,
        text_context: text_context,
        ocr_text: ocr_text,
        transcript: transcript,
        suggestions: suggestions,
        generation_result: result,
        history_pending: history_pending
      )
    rescue StandardError => e
      analysis = normalized_hash(post&.analysis)
      metadata = normalized_hash(post&.metadata)
      policy_persistence.persist_blocked!(
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
      row&.config_value("ollama_fast_model").to_s.presence ||
        row&.config_value("ollama_model").to_s.presence ||
        ENV.fetch("OLLAMA_FAST_MODEL", ENV.fetch("OLLAMA_MODEL", "mistral:7b"))
    rescue StandardError
      ENV.fetch("OLLAMA_FAST_MODEL", ENV.fetch("OLLAMA_MODEL", "mistral:7b"))
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
      metadata = profile.instagram_profile_behavior_profile&.metadata
      metadata = {} unless metadata.is_a?(Hash)
      history_conversation = metadata.dig("history_build", "conversation")
      history_conversation = {} unless history_conversation.is_a?(Hash)

      {
        profile_tags: profile.profile_tags.pluck(:name).map(&:to_s).uniq.first(10),
        recurring_topics: hash_keys(summary["topic_clusters"]),
        recurring_hashtags: hash_keys(summary["top_hashtags"]),
        frequent_people_labels: frequent_people_labels(summary["frequent_secondary_persons"]),
        suggested_openers: Array(history_conversation["suggested_openers"]).map { |value| value.to_s.byteslice(0, 80) }.reject(&:blank?).first(6),
        recent_incoming_messages: Array(history_conversation["recent_incoming_messages"]).first(2).map do |row|
          data = row.is_a?(Hash) ? row : {}
          {
            body: data["body"].to_s.byteslice(0, 140),
            created_at: data["created_at"].to_s
          }
        end,
        conversation_state: {
          dm_allowed: ActiveModel::Type::Boolean.new.cast(history_conversation["dm_allowed"]),
          has_incoming_messages: ActiveModel::Type::Boolean.new.cast(history_conversation["has_incoming_messages"]),
          can_respond_to_existing_messages: ActiveModel::Type::Boolean.new.cast(history_conversation["can_respond_to_existing_messages"]),
          outgoing_message_count: history_conversation["outgoing_message_count"].to_i
        }
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

    def signal_context(analysis:, metadata:)
      Ai::PostCommentGeneration::SignalContext.new(
        analysis: analysis,
        metadata: metadata,
        max_suggestions: MAX_SUGGESTIONS
      )
    end

    def build_scored_context(analysis:)
      Ai::ContextSignalScorer.new(profile: profile, channel: "post").build(
        current_topics: normalized_topics(analysis["topics"]),
        image_description: analysis["image_description"].to_s,
        caption: post.caption.to_s,
        limit: 12
      )
    rescue StandardError
      {
        prioritized_signals: [],
        style_profile: {},
        engagement_memory: {},
        context_keywords: []
      }
    end

    def policy_persistence
      @policy_persistence ||= Ai::PostCommentGeneration::PolicyPersistence.new(
        post: post,
        enforce_required_evidence: enforce_required_evidence?,
        required_signal_keys: REQUIRED_SIGNAL_KEYS
      )
    end

    def normalized_hash(value)
      value.is_a?(Hash) ? value.deep_dup : {}
    end

    def enforce_required_evidence?
      @enforce_required_evidence
    end
  end
end
