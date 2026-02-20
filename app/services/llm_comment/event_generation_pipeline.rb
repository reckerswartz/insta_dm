# frozen_string_literal: true

module LlmComment
  class EventGenerationPipeline
    def initialize(event:, provider:, model:)
      @event = event
      @provider = provider.to_s
      @model = model
    end

    def call
      return completed_result if event.has_llm_generated_comment?

      started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC) rescue nil
      context = event.send(:build_comment_context)
      local_intelligence = normalize_hash(context[:local_story_intelligence])
      validated_story_insights = normalize_hash(context[:validated_story_insights])
      generation_policy = normalize_hash(validated_story_insights[:generation_policy])

      event.send(:persist_validated_story_insights!, validated_story_insights)
      event.send(:persist_local_story_intelligence!, local_intelligence)
      validate_intelligence!(local_intelligence: local_intelligence, generation_policy: generation_policy)

      event.broadcast_llm_comment_generation_progress(
        stage: "context_ready",
        message: "Context prepared from local story intelligence.",
        progress: 20
      )
      technical_details = event.capture_technical_details(context)
      event.broadcast_llm_comment_generation_progress(
        stage: "model_running",
        message: "Generating suggestions with local model.",
        progress: 55
      )

      result = generator.generate!(**generation_payload(context))
      enhanced_result = result.merge(technical_details: technical_details)
      validate_model_result!(result)

      ranked = rank_suggestions(result: result, context: context)
      selected_comment, relevance_score = ranked.first
      raise "No valid comment suggestions generated" if selected_comment.to_s.blank?

      persist_completed_result!(
        result: result,
        context: context,
        ranked: ranked,
        selected_comment: selected_comment,
        relevance_score: relevance_score,
        technical_details: technical_details,
        started_at: started_at
      )

      event.broadcast_llm_comment_generation_progress(stage: "completed", message: "Comment ready.", progress: 100)
      event.broadcast_story_archive_refresh
      event.broadcast_llm_comment_generation_update(
        enhanced_result.merge(
          selected_comment: selected_comment,
          relevance_score: relevance_score,
          ranked_candidates: ranked.first(8)
        )
      )

      enhanced_result.merge(
        selected_comment: selected_comment,
        relevance_score: relevance_score,
        ranked_candidates: ranked.first(8)
      )
    end

    private

    attr_reader :event, :provider, :model

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
      if event.send(:local_story_intelligence_blank?, local_intelligence)
        reason = local_intelligence[:reason].to_s.presence || "local_story_intelligence_blank"
        source = local_intelligence[:source].to_s.presence || "unknown"
        raise InstagramProfileEvent::LocalStoryIntelligence::LocalStoryIntelligenceUnavailableError.new(
          "Local story intelligence unavailable (reason: #{reason}, source: #{source}).",
          reason: reason,
          source: source
        )
      end

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
      Ai::CommentRelevanceScorer.rank(
        suggestions: result[:comment_suggestions],
        image_description: context[:image_description],
        topics: context[:topics],
        historical_comments: context[:historical_comments]
      )
    end

    def persist_completed_result!(result:, context:, ranked:, selected_comment:, relevance_score:, technical_details:, started_at:)
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
          "ranked_candidates" => ranked.first(8).map { |text, value| { "comment" => text, "score" => value } },
          "selected_comment" => selected_comment,
          "selected_relevance_score" => relevance_score,
          "generated_at" => Time.current.iso8601,
          "processing_ms" => duration_ms,
          "pipeline" => "validated_story_intelligence_v3"
        )
      )
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
