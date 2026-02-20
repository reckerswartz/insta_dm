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
      LlmComment::EventGenerationPipeline.new(
        event: self,
        provider: provider,
        model: model
      ).call
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
      Ai::ProfileInsightStore.new.ingest_story!(
        profile: profile,
        event: self,
        intelligence: verified_story_facts.presence || local_story_intelligence
      )

      post_payload = {
        post: {
          event_id: id,
          media_type: raw_metadata["media_type"].to_s.presence || media&.blob&.content_type.to_s.presence || "unknown",
          occurred_at: (occurred_at || detected_at || Time.current).iso8601
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
      scored_context = Ai::ContextSignalScorer.new(profile: profile, channel: "story").build(
        current_topics: topics,
        image_description: image_description.to_s,
        caption: nil,
        limit: 12
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
      post_payload[:scored_context] = scored_context
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
        conversational_voice: conversational_voice,
        scored_context: scored_context
      }
    end

  end
end
