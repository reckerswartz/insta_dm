module Ai
  class PostCommentGenerationService
    REQUIRED_SIGNAL_KEYS = [].freeze
    MAX_SUGGESTIONS = 8
    UNUSABLE_VISUAL_CONTEXT_PATTERNS = [
      /no image or video content available/i,
      /visual analysis unavailable/i,
      /image analysis unavailable/i,
      /image_analysis_error/i,
      /analysis error/i,
      /failed to open tcp connection/i,
      /connection refused/i,
      /net::readtimeout/i,
      /errn[o0]::econnrefused/i,
      /local ai timeout/i
    ].freeze
    BASE_MIN_RELEVANCE_SCORE =
      ENV.fetch("POST_COMMENT_MIN_RELEVANCE_SCORE", "1.1").to_f.clamp(0.5, 3.0)
    MIN_ELIGIBLE_SUGGESTIONS =
      ENV.fetch("POST_COMMENT_MIN_ELIGIBLE_SUGGESTIONS", "2").to_i.clamp(1, MAX_SUGGESTIONS)
    HIGH_RELEVANCE_OVERRIDE_SCORE =
      ENV.fetch("POST_COMMENT_HIGH_RELEVANCE_OVERRIDE_SCORE", "1.55").to_f.clamp(0.5, 3.0)

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
      engagement_classification = classify_post_engagement(analysis: analysis, metadata: metadata)
      history_ready = ActiveModel::Type::Boolean.new.cast(preparation["ready_for_comment_generation"])
      missing_required = signals.missing_required_signals
      history_pending = !history_ready
      missing_signals = missing_required.dup
      missing_signals << "history" if history_pending

      unless ActiveModel::Type::Boolean.new.cast(engagement_classification["engagement_suitable"])
        return policy_persistence.persist_blocked!(
          analysis: analysis,
          metadata: metadata,
          preparation: preparation,
          missing_signals: [ "engagement_suitability" ],
          reason_code: "unsuitable_for_engagement",
          error_message: engagement_classification["summary"].to_s.presence || "Post is not suitable for comment engagement.",
          engagement_classification: engagement_classification
        )
      end

      if missing_required.any? && enforce_required_evidence?
        return policy_persistence.persist_blocked!(
          analysis: analysis,
          metadata: metadata,
          preparation: preparation,
          missing_signals: missing_signals,
          reason_code: "missing_required_evidence",
          engagement_classification: engagement_classification
        )
      end

      topics = signals.topics
      image_description = signals.image_description

      if unusable_visual_context?(image_description)
        return policy_persistence.persist_blocked!(
          analysis: analysis,
          metadata: metadata,
          preparation: preparation,
          missing_signals: [ "visual_context" ],
          reason_code: "missing_visual_context",
          engagement_classification: engagement_classification
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
          error_message: result[:error_message].to_s.presence || "Comment generation produced no valid suggestions.",
          engagement_classification: engagement_classification
        )
      end

      relevance_evaluation = evaluate_suggestions_relevance(
        suggestions: suggestions,
        image_description: image_description,
        topics: topics,
        scored_context: scored_context,
        engagement_classification: engagement_classification
      )
      suggestions = Array(relevance_evaluation["eligible_suggestions"])

      if suggestions.empty?
        return policy_persistence.persist_blocked!(
          analysis: analysis,
          metadata: metadata,
          preparation: preparation,
          missing_signals: [ "relevance_threshold" ],
          reason_code: "low_relevance_suggestions",
          error_message: "Generated suggestions did not pass the relevance quality gate.",
          engagement_classification: engagement_classification,
          relevance_evaluation: relevance_evaluation
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
        history_pending: history_pending,
        engagement_classification: engagement_classification,
        relevance_evaluation: relevance_evaluation
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
      row&.config_value("ollama_comment_model").to_s.presence ||
        row&.config_value("ollama_fast_model").to_s.presence ||
        row&.config_value("ollama_model").to_s.presence ||
        row&.config_value("ollama_vision_model").to_s.presence ||
        ENV.fetch("OLLAMA_COMMENT_MODEL", Ai::ModelDefaults.comment_model)
    rescue StandardError
      ENV.fetch("OLLAMA_COMMENT_MODEL", Ai::ModelDefaults.comment_model)
    end

    def post_payload
      builder = Ai::PostAnalysisContextBuilder.new(profile: profile, post: post)
      payload = builder.payload
      payload[:rules] = (payload[:rules].is_a?(Hash) ? payload[:rules] : {}).merge(
        require_history_context: false,
        require_face_signal: false,
        require_ocr_signal: false,
        require_text_context: false
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

    def classify_post_engagement(analysis:, metadata:)
      classifier = Ai::PostEngagementSuitabilityClassifier.new(
        profile: profile,
        post: post,
        analysis: analysis,
        metadata: metadata
      )
      classification = classifier.classify
      classification.is_a?(Hash) ? classification : {}
    rescue StandardError
      {}
    end

    def evaluate_suggestions_relevance(suggestions:, image_description:, topics:, scored_context:, engagement_classification:)
      min_score = BASE_MIN_RELEVANCE_SCORE
      min_score = relevance_min_score_for(engagement_classification: engagement_classification)
      ranked = Ai::CommentRelevanceScorer.annotate_llm_order_with_breakdown(
        suggestions: suggestions,
        image_description: image_description,
        topics: topics,
        historical_comments: historical_comments,
        scored_context: scored_context
      )
      ranked_rows = Array(ranked).sort_by { |row| -row[:relevance_score].to_f }.first(MAX_SUGGESTIONS)
      eligible = ranked_rows.select { |row| row[:relevance_score].to_f >= min_score }
      eligible_confident_count = eligible.count { |row| %w[medium high].include?(row[:confidence_level].to_s) }
      eligible_suggestions = eligible.map { |row| row[:comment].to_s.strip }.reject(&:blank?).uniq.first(MAX_SUGGESTIONS)
      top_relevance_score = ranked_rows.first&.dig(:relevance_score).to_f.round(3)
      high_score_override = top_relevance_score >= HIGH_RELEVANCE_OVERRIDE_SCORE
      quality_gate_passed = eligible_suggestions.length >= MIN_ELIGIBLE_SUGGESTIONS && eligible_confident_count.positive?
      eligible_suggestions = [] unless quality_gate_passed || high_score_override

      {
        "min_score" => min_score.round(3),
        "required_eligible_count" => MIN_ELIGIBLE_SUGGESTIONS,
        "eligible_count" => eligible_suggestions.length,
        "eligible_medium_or_high_count" => eligible_confident_count,
        "quality_gate_passed" => quality_gate_passed,
        "high_score_override_score" => HIGH_RELEVANCE_OVERRIDE_SCORE.round(3),
        "high_score_override_applied" => high_score_override && !quality_gate_passed,
        "top_relevance_score" => top_relevance_score,
        "eligible_suggestions" => eligible_suggestions,
        "ranked_suggestions" => ranked_rows.map { |row| normalize_ranked_suggestion(row) },
        "evaluated_at" => Time.current.iso8601(3)
      }
    rescue StandardError => e
      {
        "min_score" => min_score.round(3),
        "required_eligible_count" => MIN_ELIGIBLE_SUGGESTIONS,
        "eligible_count" => Array(suggestions).length,
        "eligible_medium_or_high_count" => nil,
        "quality_gate_passed" => nil,
        "high_score_override_score" => HIGH_RELEVANCE_OVERRIDE_SCORE.round(3),
        "high_score_override_applied" => nil,
        "top_relevance_score" => nil,
        "eligible_suggestions" => Array(suggestions).map(&:to_s).map(&:strip).reject(&:blank?).uniq.first(MAX_SUGGESTIONS),
        "ranked_suggestions" => [],
        "error_class" => e.class.name,
        "error_message" => e.message.to_s,
        "evaluated_at" => Time.current.iso8601(3)
      }
    end

    def relevance_min_score_for(engagement_classification:)
      classification = engagement_classification.is_a?(Hash) ? engagement_classification : {}
      score = BASE_MIN_RELEVANCE_SCORE
      personal_signal = (
        classification["personal_signal_score"] ||
        classification[:personal_signal_score] ||
        classification["content_signal_score"] ||
        classification[:content_signal_score]
      ).to_i
      ownership = classification["ownership"].to_s.presence || classification[:ownership].to_s
      profile_tags = Array(classification["profile_tags"] || classification[:profile_tags]).map { |value| value.to_s.downcase.strip }

      score -= 0.1 if personal_signal >= 4
      score += 0.1 if personal_signal <= 1
      score += 0.15 unless ownership == "original"
      score += 0.15 if profile_tags.include?("page")

      score.clamp(0.5, 3.0).round(3)
    end

    def normalize_ranked_suggestion(row)
      item = row.is_a?(Hash) ? row : {}
      factors = item[:factors].is_a?(Hash) ? item[:factors] : {}

      {
        "comment" => item[:comment].to_s,
        "score" => item[:score].to_f.round(3),
        "relevance_score" => item[:relevance_score].to_f.round(3),
        "llm_rank" => item[:llm_rank].to_i,
        "llm_order_bonus" => item[:llm_order_bonus].to_f.round(3),
        "auto_post_eligible" => ActiveModel::Type::Boolean.new.cast(item[:auto_post_eligible]),
        "confidence_level" => item[:confidence_level].to_s.presence || "low",
        "factors" => factors
      }
    end

    def unusable_visual_context?(value)
      text = value.to_s.strip
      return true if text.blank?

      UNUSABLE_VISUAL_CONTEXT_PATTERNS.any? { |pattern| text.match?(pattern) }
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
