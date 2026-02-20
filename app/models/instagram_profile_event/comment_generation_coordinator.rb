require 'active_support/concern'

module InstagramProfileEvent::CommentGenerationCoordinator
  extend ActiveSupport::Concern

  included do
    def has_llm_generated_comment?
      llm_generated_comment.present?
    end
    def llm_comment_in_progress?
      %w[queued running].include?(llm_comment_status.to_s)
    end
    def queue_llm_comment_generation!(job_id: nil)
      update!(
        llm_comment_status: "queued",
        llm_comment_job_id: job_id.to_s.presence || llm_comment_job_id,
        llm_comment_last_error: nil
      )

      broadcast_llm_comment_generation_queued(job_id: job_id)
    end
    def mark_llm_comment_running!(job_id: nil)
      update!(
        llm_comment_status: "running",
        llm_comment_job_id: job_id.to_s.presence || llm_comment_job_id,
        llm_comment_attempts: llm_comment_attempts.to_i + 1,
        llm_comment_last_error: nil
      )

      broadcast_llm_comment_generation_start
    end
    def mark_llm_comment_failed!(error:)
      update!(
        llm_comment_status: "failed",
        llm_comment_last_error: error.message.to_s,
        llm_comment_metadata: (llm_comment_metadata.is_a?(Hash) ? llm_comment_metadata : {}).merge(
          "last_failure" => {
            "error_class" => error.class.name,
            "error_message" => error.message.to_s,
            "failed_at" => Time.current.iso8601
          }
        )
      )

      broadcast_llm_comment_generation_error(error.message)
    rescue StandardError
      nil
    end
    def mark_llm_comment_skipped!(message:, reason: nil, source: nil)
      intel_status =
        if source.to_s == "validated_story_policy"
          "policy_blocked"
        else
          "unavailable"
        end
      details = {
        "error_class" => "LocalStoryIntelligenceUnavailableError",
        "error_message" => message.to_s,
        "failed_at" => Time.current.iso8601,
        "reason" => reason.to_s.presence,
        "source" => source.to_s.presence
      }.compact

      update!(
        llm_comment_status: "skipped",
        llm_comment_last_error: message.to_s,
        llm_comment_metadata: (llm_comment_metadata.is_a?(Hash) ? llm_comment_metadata : {}).merge(
          "last_failure" => details,
          "local_story_intelligence_status" => intel_status
        )
      )

      broadcast_llm_comment_generation_skipped(
        message: message.to_s,
        reason: reason,
        source: source
      )
    rescue StandardError
      nil
    end
    def generate_llm_comment!(provider: :local, model: nil)
      if has_llm_generated_comment?
        update_columns(
          llm_comment_status: "completed",
          llm_comment_last_error: nil,
          updated_at: Time.current
        )

        return {
          status: "already_completed",
          selected_comment: llm_generated_comment,
          relevance_score: llm_comment_relevance_score
        }
      end

      started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC) rescue nil
      context = build_comment_context
      local_intel = context[:local_story_intelligence].is_a?(Hash) ? context[:local_story_intelligence] : {}
      validated_story_insights = context[:validated_story_insights].is_a?(Hash) ? context[:validated_story_insights] : {}
      generation_policy = validated_story_insights[:generation_policy].is_a?(Hash) ? validated_story_insights[:generation_policy] : {}
      persist_validated_story_insights!(validated_story_insights)
      persist_local_story_intelligence!(local_intel)
      if local_story_intelligence_blank?(local_intel)
        reason = local_intel[:reason].to_s.presence || "local_story_intelligence_blank"
        source = local_intel[:source].to_s.presence || "unknown"
        raise InstagramProfileEvent::LocalStoryIntelligence::LocalStoryIntelligenceUnavailableError.new(
          "Local story intelligence unavailable (reason: #{reason}, source: #{source}).",
          reason: reason,
          source: source
        )
      end
      unless ActiveModel::Type::Boolean.new.cast(generation_policy[:allow_comment])
        policy_reason_code = generation_policy[:reason_code].to_s.presence || "policy_blocked"
        policy_reason = generation_policy[:reason].to_s.presence || "Comment generation blocked by verified story policy."
        raise InstagramProfileEvent::LocalStoryIntelligence::LocalStoryIntelligenceUnavailableError.new(
          policy_reason,
          reason: policy_reason_code,
          source: "validated_story_policy"
        )
      end
      broadcast_llm_comment_generation_progress(stage: "context_ready", message: "Context prepared from local story intelligence.", progress: 20)
      technical_details = capture_technical_details(context)
      broadcast_llm_comment_generation_progress(stage: "model_running", message: "Generating suggestions with local model.", progress: 55)

      generator = Ai::LocalEngagementCommentGenerator.new(
        ollama_client: Ai::OllamaClient.new,
        model: model
      )

      result = generator.generate!(
        post_payload: context[:post_payload],
        image_description: context[:image_description],
        topics: context[:topics],
        author_type: context[:author_type],
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
        conversational_voice: context[:conversational_voice]
      )
      enhanced_result = result.merge(technical_details: technical_details)

      unless LLM_SUCCESS_STATUSES.include?(result[:status].to_s)
        raise "Local pipeline did not produce valid model suggestions (fallback blocked): #{result[:error_message]}"
      end

      ranked = Ai::CommentRelevanceScorer.rank(
        suggestions: result[:comment_suggestions],
        image_description: context[:image_description],
        topics: context[:topics],
        historical_comments: context[:historical_comments]
      )

      selected_comment, score = ranked.first
      raise "No valid comment suggestions generated" if selected_comment.to_s.blank?

      duration_ms =
        if started_at
          ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at) * 1000.0).round
        end

      update!(
        llm_generated_comment: selected_comment,
        llm_comment_generated_at: Time.current,
        llm_comment_model: result[:model],
        llm_comment_provider: provider.to_s,
        llm_comment_status: "completed",
        llm_comment_relevance_score: score,
        llm_comment_last_error: nil,
        llm_comment_metadata: (llm_comment_metadata.is_a?(Hash) ? llm_comment_metadata : {}).merge(
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
          "ranked_candidates" => ranked.first(8).map { |text, value| { "comment" => text, "score" => value } },
          "selected_comment" => selected_comment,
          "selected_relevance_score" => score,
          "generated_at" => Time.current.iso8601,
          "processing_ms" => duration_ms,
          "pipeline" => "validated_story_intelligence_v3"
        )
      )

      broadcast_llm_comment_generation_progress(stage: "completed", message: "Comment ready.", progress: 100)
      broadcast_story_archive_refresh
      broadcast_llm_comment_generation_update(
        enhanced_result.merge(
          selected_comment: selected_comment,
          relevance_score: score,
          ranked_candidates: ranked.first(8)
        )
      )

      enhanced_result.merge(
        selected_comment: selected_comment,
        relevance_score: score,
        ranked_candidates: ranked.first(8)
      )
    end
    def reply_comment
      metadata["reply_comment"] if metadata.is_a?(Hash)
    end
    def llm_comment_consistency
      status = llm_comment_status.to_s

      if status == "completed" && llm_generated_comment.blank?
        errors.add(:llm_generated_comment, "must be present when status is completed")
      end

      if status == "completed" && llm_comment_generated_at.blank?
        errors.add(:llm_comment_generated_at, "must be present when status is completed")
      end

      if status == "completed" && llm_comment_provider.blank?
        errors.add(:llm_comment_provider, "must be present when status is completed")
      end

      if llm_generated_comment.blank? && llm_comment_generated_at.present?
        errors.add(:llm_generated_comment, "must be present when generated_at is set")
      end
    end
    def build_comment_context
      profile = instagram_profile
      raw_metadata = metadata.is_a?(Hash) ? metadata : {}
      local_story_intelligence = local_story_intelligence_payload
      validated_story_insights = Ai::VerifiedStoryInsightBuilder.new(
        profile: profile,
        local_story_intelligence: local_story_intelligence,
        metadata: raw_metadata
      ).build
      verified_story_facts = validated_story_insights[:verified_story_facts].is_a?(Hash) ? validated_story_insights[:verified_story_facts] : {}

      post_payload = {
        post: {
          event_id: id,
          media_type: raw_metadata["media_type"].to_s.presence || media&.blob&.content_type.to_s.presence || "unknown"
        },
        author_profile: {
          username: profile&.username,
          display_name: profile&.display_name,
          bio_keywords: extract_topics_from_profile(profile).first(10)
        },
        rules: {
          max_length: 140,
          require_local_pipeline: true,
          require_verified_story_facts: true,
          block_unverified_generation: true,
          verified_only: true
        }
      }

      image_description = build_story_image_description(local_story_intelligence: verified_story_facts.presence || local_story_intelligence)

      historical_comments = recent_llm_comments_for_profile(profile)
      topics = (Array(verified_story_facts[:topics]) + extract_topics_from_profile(profile)).map(&:to_s).reject(&:blank?).uniq.first(20)
      historical_story_context = recent_story_intelligence_context(profile)
      profile_preparation = latest_profile_comment_preparation(profile)
      verified_profile_history = recent_analyzed_profile_history(profile)
      conversational_voice = build_conversational_voice_profile(
        profile: profile,
        historical_story_context: historical_story_context,
        verified_profile_history: verified_profile_history,
        profile_preparation: profile_preparation
      )
      historical_comparison = build_historical_comparison(
        current: verified_story_facts.presence || local_story_intelligence,
        historical_story_context: historical_story_context
      )
      validated_story_insights = apply_historical_validation(
        validated_story_insights: validated_story_insights,
        historical_comparison: historical_comparison
      )
      story_ownership_classification = validated_story_insights[:ownership_classification].is_a?(Hash) ? validated_story_insights[:ownership_classification] : {}
      generation_policy = validated_story_insights[:generation_policy].is_a?(Hash) ? validated_story_insights[:generation_policy] : {}
      cv_ocr_evidence = build_cv_ocr_evidence(local_story_intelligence: verified_story_facts.presence || local_story_intelligence)

      post_payload[:historical_comparison] = historical_comparison
      post_payload[:cv_ocr_evidence] = cv_ocr_evidence
      post_payload[:story_ownership_classification] = story_ownership_classification
      post_payload[:generation_policy] = generation_policy
      post_payload[:profile_comment_preparation] = profile_preparation
      post_payload[:conversational_voice] = conversational_voice
      post_payload[:verified_profile_history] = verified_profile_history
      historical_context = build_compact_historical_context(
        profile: profile,
        historical_story_context: historical_story_context,
        verified_profile_history: verified_profile_history,
        profile_preparation: profile_preparation
      )

      {
        post_payload: post_payload,
        image_description: image_description,
        topics: topics,
        author_type: determine_author_type(profile),
        historical_comments: historical_comments,
        historical_context: historical_context,
        historical_story_context: historical_story_context,
        historical_comparison: historical_comparison,
        cv_ocr_evidence: cv_ocr_evidence,
        local_story_intelligence: local_story_intelligence,
        verified_story_facts: verified_story_facts,
        story_ownership_classification: story_ownership_classification,
        generation_policy: generation_policy,
        validated_story_insights: validated_story_insights,
        profile_preparation: profile_preparation,
        verified_profile_history: verified_profile_history,
        conversational_voice: conversational_voice
      }
    end

  end
end
