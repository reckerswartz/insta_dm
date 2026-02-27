# frozen_string_literal: true

module LlmComment
  class EventGenerationPipeline
    MIN_VALIDATION_SCORE = ENV.fetch("LLM_COMMENT_MIN_VALIDATION_SCORE", "1.0").to_f.clamp(0.0, 3.0)

    def initialize(event:, provider:, model:, skip_media_stage_reporting: false, local_story_intelligence: nil)
      @event = event
      @provider = provider.to_s
      @model = model
      @skip_media_stage_reporting = ActiveModel::Type::Boolean.new.cast(skip_media_stage_reporting)
      @local_story_intelligence = normalize_hash(local_story_intelligence)
    end

    def call
      return completed_result if event.has_llm_generated_comment?

      started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC) rescue nil
      unless skip_media_stage_reporting?
        report_stage!(
          stage: "context_matching",
          state: "running",
          progress: 44,
          message: "Building prompt context from story intelligence."
        )
        report_stage!(
          stage: "face_recognition",
          state: "skipped",
          progress: 34,
          message: "Face enrichment is deferred and non-blocking."
        )
      end
      context = event.send(:build_comment_context, local_story_intelligence: local_story_intelligence)
      local_intelligence = normalize_hash(context[:local_story_intelligence])
      validated_story_insights = normalize_hash(context[:validated_story_insights])
      generation_policy = normalize_hash(validated_story_insights[:generation_policy])

      event.send(:persist_validated_story_insights!, validated_story_insights)
      event.send(:persist_local_story_intelligence!, local_intelligence)
      validate_intelligence!(local_intelligence: local_intelligence, generation_policy: generation_policy)
      report_stage!(
        stage: "context_matching",
        state: "completed",
        progress: 46,
        message: "Context enrichment and history matching completed."
      )

      event.broadcast_llm_comment_generation_progress(
        stage: "context_ready",
        message: "Context prepared from direct media intelligence.",
        progress: 46,
        stage_statuses: event.llm_processing_stages
      )
      technical_details = event.capture_technical_details(context)
      report_stage!(
        stage: "prompt_construction",
        state: "completed",
        progress: 58,
        message: "Prompt construction completed."
      )
      report_stage!(
        stage: "llm_generation",
        state: "running",
        progress: 68,
        message: "Generating comments with local model."
      )
      event.broadcast_llm_comment_generation_progress(
        stage: "model_running",
        message: "Generating suggestions with local model.",
        progress: 68,
        stage_statuses: event.llm_processing_stages
      )

      result = generator.generate!(**generation_payload(context))
      enhanced_result = result.merge(technical_details: technical_details)
      validate_model_result!(result)
      report_stage!(
        stage: "llm_generation",
        state: "completed",
        progress: 82,
        message: "Comment suggestions generated."
      )
      report_stage!(
        stage: "relevance_scoring",
        state: "running",
        progress: 90,
        message: "Validating generated suggestions with lightweight relevance checks."
      )

      ranked = rank_suggestions(result: result, context: context)
      selected = select_candidate(ranked: ranked)
      selected_comment = selected.to_h[:comment].to_s
      relevance_score = selected.to_h[:relevance_score].to_f
      selected_breakdown = selected.to_h[:factors].is_a?(Hash) ? selected[:factors] : {}
      raise "No valid comment suggestions generated" if selected_comment.to_s.blank?
      report_stage!(
        stage: "relevance_scoring",
        state: "completed",
        progress: 96,
        message: "Suggestion validation completed.",
        details: {
          final_score: relevance_score,
          selection_score: selected.to_h[:score].to_f,
          llm_rank: selected.to_h[:llm_rank].to_i,
          confidence_level: selected.to_h[:confidence_level],
          auto_post_eligible: selected.to_h[:auto_post_eligible]
        }
      )

      persist_completed_result!(
        result: result,
        context: context,
        ranked: ranked,
        selected_comment: selected_comment,
        relevance_score: relevance_score,
        relevance_breakdown: selected_breakdown,
        selected_confidence_level: selected.to_h[:confidence_level].to_s,
        selected_auto_post_eligible: ActiveModel::Type::Boolean.new.cast(selected.to_h[:auto_post_eligible]),
        technical_details: technical_details,
        started_at: started_at
      )

      event.broadcast_llm_comment_generation_progress(stage: "completed", message: "Comment ready.", progress: 100)
      event.broadcast_story_archive_refresh
      event.broadcast_llm_comment_generation_update(
        enhanced_result.merge(
          selected_comment: selected_comment,
          relevance_score: relevance_score,
          relevance_breakdown: selected_breakdown,
          ranked_candidates: ranked.first(8),
          generation_inputs: build_generation_inputs(context: context, result: result),
          policy_diagnostics: (result[:policy_diagnostics].is_a?(Hash) ? result[:policy_diagnostics] : {})
        )
      )

      enhanced_result.merge(
        selected_comment: selected_comment,
        relevance_score: relevance_score,
        relevance_breakdown: selected_breakdown,
        ranked_candidates: ranked.first(8),
        generation_inputs: build_generation_inputs(context: context, result: result),
        policy_diagnostics: (result[:policy_diagnostics].is_a?(Hash) ? result[:policy_diagnostics] : {})
      )
    end

    private

    attr_reader :event, :provider, :model

    def skip_media_stage_reporting?
      @skip_media_stage_reporting
    end

    def local_story_intelligence
      @local_story_intelligence
    end

    def completed_result
      event.update_columns(
        llm_comment_status: "completed",
        llm_comment_last_error: nil,
        updated_at: Time.current
      )

      {
        status: "already_completed",
        selected_comment: event.llm_generated_comment,
        relevance_score: event.llm_comment_relevance_score
      }
    end

    def generator
      @generator ||= Ai::LocalEngagementCommentGenerator.new(
        ollama_client: Ai::OllamaClient.new,
        model: model
      )
    end

    def generation_payload(context)
      {
        post_payload: context[:post_payload],
        image_description: context[:image_description],
        topics: context[:topics],
        author_type: context[:author_type],
        channel: "story",
        historical_comments: context[:historical_comments],
        historical_context: context[:historical_context],
        historical_story_context: context[:historical_story_context],
        local_story_intelligence: context[:local_story_intelligence],
        historical_comparison: context[:historical_comparison],
        cv_ocr_evidence: context[:cv_ocr_evidence],
        verified_story_facts: context[:verified_story_facts],
        story_ownership_classification: context[:story_ownership_classification],
        generation_policy: context[:generation_policy],
        profile_preparation: context[:profile_preparation],
        verified_profile_history: context[:verified_profile_history],
        conversational_voice: context[:conversational_voice],
        scored_context: context[:scored_context]
      }
    end

    def validate_intelligence!(local_intelligence:, generation_policy:)
      return if ActiveModel::Type::Boolean.new.cast(generation_policy[:allow_comment])

      policy_reason_code = generation_policy[:reason_code].to_s.presence || "policy_blocked"
      policy_reason = generation_policy[:reason].to_s.presence || "Comment generation blocked by verified story policy."
      raise InstagramProfileEvent::LocalStoryIntelligence::LocalStoryIntelligenceUnavailableError.new(
        policy_reason,
        reason: policy_reason_code,
        source: "validated_story_policy"
      )
    end

    def validate_model_result!(result)
      return if event.class::LLM_SUCCESS_STATUSES.include?(result[:status].to_s)

      raise "Local pipeline did not produce valid model suggestions (fallback blocked): #{result[:error_message]}"
    end

    def rank_suggestions(result:, context:)
      rows = Ai::CommentRelevanceScorer.annotate_llm_order_with_breakdown(
        suggestions: result[:comment_suggestions],
        image_description: context[:image_description],
        topics: context[:topics],
        historical_comments: context[:historical_comments],
        scored_context: context[:scored_context],
        verified_story_facts: context[:verified_story_facts]
      )
      rows.sort_by { |row| [ -row[:score].to_f, row[:llm_rank].to_i ] }
    end

    def select_candidate(ranked:)
      rows = Array(ranked).select { |row| row.is_a?(Hash) }
      top = rows.first
      return {} unless top
      return top if top[:relevance_score].to_f >= MIN_VALIDATION_SCORE

      rows.find { |row| row[:relevance_score].to_f >= MIN_VALIDATION_SCORE } || top
    end

    def persist_completed_result!(result:, context:, ranked:, selected_comment:, relevance_score:, relevance_breakdown:, selected_confidence_level:, selected_auto_post_eligible:, technical_details:, started_at:)
      duration_ms =
        if started_at
          ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at) * 1000.0).round
        end

      event.update!(
        llm_generated_comment: selected_comment,
        llm_comment_generated_at: Time.current,
        llm_comment_model: result[:model],
        llm_comment_provider: provider,
        llm_comment_status: "completed",
        llm_comment_relevance_score: relevance_score,
        llm_comment_last_error: nil,
        llm_comment_metadata: normalized_metadata.merge(
          "prompt" => result[:prompt],
          "source" => result[:source],
          "fallback_used" => ActiveModel::Type::Boolean.new.cast(result[:fallback_used]),
          "generation_status" => result[:status],
          "llm_telemetry" => result[:llm_telemetry].is_a?(Hash) ? result[:llm_telemetry] : {},
          "technical_details" => technical_details,
          "local_story_intelligence" => context[:local_story_intelligence],
          "historical_story_context_used" => Array(context[:historical_story_context]).first(12),
          "historical_comparison" => context[:historical_comparison],
          "cv_ocr_evidence" => context[:cv_ocr_evidence],
          "verified_story_facts" => context[:verified_story_facts],
          "ownership_classification" => context[:story_ownership_classification],
          "generation_policy" => context[:generation_policy],
          "validated_story_insights" => context[:validated_story_insights],
          "scored_context" => context[:scored_context],
          "generation_inputs" => build_generation_inputs(context: context, result: result),
          "policy_diagnostics" => (result[:policy_diagnostics].is_a?(Hash) ? result[:policy_diagnostics] : {}),
          "ranked_candidates" => ranked.first(8).map do |row|
            {
              "comment" => row[:comment],
              "score" => row[:score],
              "relevance_score" => row[:relevance_score],
              "llm_rank" => row[:llm_rank],
              "llm_order_bonus" => row[:llm_order_bonus],
              "auto_post_eligible" => row[:auto_post_eligible],
              "confidence_level" => row[:confidence_level],
              "factors" => row[:factors]
            }
          end,
          "selected_comment" => selected_comment,
          "selected_relevance_score" => relevance_score,
          "selected_relevance_breakdown" => relevance_breakdown,
          "selected_confidence_level" => selected_confidence_level,
          "selected_auto_post_eligible" => selected_auto_post_eligible,
          "auto_post_allowed" => selected_auto_post_eligible,
          "manual_review_reason" => (selected_auto_post_eligible ? nil : "low_relevance_manual_review"),
          "processing_stages" => event.llm_processing_stages,
          "generated_at" => Time.current.iso8601,
          "processing_ms" => duration_ms,
          "pipeline" => "validated_story_intelligence_v3"
        )
      )
    end

    def build_generation_inputs(context:, result:)
      prompt_inputs = result[:prompt_inputs].is_a?(Hash) ? result[:prompt_inputs] : {}
      verified_story_facts = context[:verified_story_facts].is_a?(Hash) ? context[:verified_story_facts] : {}
      profile_topics = Array(context[:profile_topics]).map(&:to_s).map(&:strip).reject(&:blank?).uniq
      media_topics = Array(context[:media_topics]).map(&:to_s).map(&:strip).reject(&:blank?).uniq
      selected_topics = Array(context[:topics]).map(&:to_s).map(&:strip).reject(&:blank?).uniq

      {
        "selected_topics" => selected_topics.first(12),
        "media_topics" => media_topics.first(12),
        "profile_topics" => profile_topics.first(8),
        "visual_anchors" => Array(prompt_inputs[:visual_anchors] || prompt_inputs["visual_anchors"]).map(&:to_s).map(&:strip).reject(&:blank?).uniq.first(12),
        "context_keywords" => Array(prompt_inputs[:context_keywords] || prompt_inputs["context_keywords"]).map(&:to_s).map(&:strip).reject(&:blank?).uniq.first(18),
        "situational_cues" => Array(prompt_inputs[:situational_cues] || prompt_inputs["situational_cues"]).map(&:to_s).map(&:strip).reject(&:blank?).uniq.first(6),
        "content_mode" => (prompt_inputs[:content_mode] || prompt_inputs["content_mode"]).to_s.presence,
        "image_description" => context[:image_description].to_s.byteslice(0, 220),
        "media_type" => context.dig(:post_payload, :post, :media_type).to_s.presence,
        "signal_score" => verified_story_facts[:signal_score].to_i
      }.compact
    rescue StandardError
      {}
    end

    def report_stage!(stage:, state:, progress:, message:, details: nil)
      stages = event.record_llm_processing_stage!(
        stage: stage,
        state: state,
        progress: progress,
        message: message,
        details: details
      )

      event.broadcast_llm_comment_generation_progress(
        stage: stage,
        message: message,
        progress: progress,
        details: details,
        stage_statuses: stages
      )
    rescue StandardError
      nil
    end

    def normalized_metadata
      event.llm_comment_metadata.is_a?(Hash) ? event.llm_comment_metadata : {}
    end

    def normalize_hash(value)
      return {} unless value.is_a?(Hash)

      value.deep_symbolize_keys
    end
  end
end
