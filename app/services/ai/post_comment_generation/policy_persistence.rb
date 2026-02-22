# frozen_string_literal: true

module Ai
  module PostCommentGeneration
    class PolicyPersistence
      def initialize(post:, enforce_required_evidence:, required_signal_keys:)
        @post = post
        @enforce_required_evidence = ActiveModel::Type::Boolean.new.cast(enforce_required_evidence)
        @required_signal_keys = Array(required_signal_keys).map(&:to_s).freeze
      end

      def persist_success!(
        analysis:,
        metadata:,
        preparation:,
        missing_required:,
        missing_signals:,
        face_count:,
        text_context:,
        ocr_text:,
        transcript:,
        suggestions:,
        generation_result:,
        history_pending:,
        engagement_classification: nil,
        relevance_evaluation: nil
      )
        analysis_hash = normalize_hash(analysis)
        metadata_hash = normalize_hash(metadata)
        classification = normalize_engagement_classification(engagement_classification)
        relevance = normalize_relevance_evaluation(relevance_evaluation)

        analysis_hash["comment_suggestions"] = suggestions
        analysis_hash["comment_generation_status"] = generation_result[:status].to_s.presence || "ok"
        analysis_hash["comment_generation_source"] = generation_result[:source].to_s.presence || "ollama"
        analysis_hash["comment_generation_fallback_used"] = ActiveModel::Type::Boolean.new.cast(generation_result[:fallback_used])
        analysis_hash["comment_generation_error"] = generation_result[:error_message].to_s.presence
        analysis_hash["engagement_classification"] = classification if classification
        if relevance
          analysis_hash["comment_relevance_min_score"] = relevance["min_score"]
          analysis_hash["comment_relevance_top_score"] = relevance["top_relevance_score"]
          analysis_hash["comment_relevance_ranking"] = Array(relevance["ranked_suggestions"]).first(8)
        end

        metadata_hash["comment_generation_policy"] = {
          "status" => policy_status(missing_required: missing_required, history_pending: history_pending),
          "required_signals" => required_signal_keys,
          "missing_signals" => missing_signals,
          "enforce_required_evidence" => enforce_required_evidence?,
          "history_ready" => ActiveModel::Type::Boolean.new.cast(preparation["ready_for_comment_generation"]),
          "history_reason_code" => preparation["reason_code"].to_s.presence,
          "face_count" => face_count,
          "text_context_present" => text_context.present?,
          "ocr_text_present" => ocr_text.present?,
          "transcript_present" => transcript.present?,
          "engagement_classification" => classification,
          "relevance" => relevance_policy_summary(relevance),
          "updated_at" => Time.current.iso8601(3)
        }.compact
        metadata_hash["engagement_classification"] = classification if classification

        post.update!(analysis: analysis_hash, metadata: metadata_hash) if post&.persisted?

        {
          blocked: false,
          status: analysis_hash["comment_generation_status"],
          source: analysis_hash["comment_generation_source"],
          suggestions_count: suggestions.length,
          reason_code: nil,
          history_reason_code: preparation["reason_code"].to_s.presence
        }
      end

      def persist_blocked!(analysis:, metadata:, preparation:, missing_signals:, reason_code:, error_message: nil, engagement_classification: nil, relevance_evaluation: nil)
        analysis_hash = normalize_hash(analysis)
        metadata_hash = normalize_hash(metadata)
        missing = Array(missing_signals).map(&:to_s).map(&:strip).reject(&:blank?).uniq
        reason = blocked_reason(missing_signals: missing, fallback_reason_code: reason_code)
        blocked_status = blocked_status_for(reason_code: reason_code)
        classification = normalize_engagement_classification(engagement_classification)
        relevance = normalize_relevance_evaluation(relevance_evaluation)

        analysis_hash["comment_suggestions"] = []
        analysis_hash["comment_generation_status"] = blocked_status
        analysis_hash["comment_generation_source"] = "policy"
        analysis_hash["comment_generation_fallback_used"] = false
        analysis_hash["comment_generation_error"] = error_message.to_s.presence || reason
        analysis_hash["engagement_classification"] = classification if classification
        if relevance
          analysis_hash["comment_relevance_min_score"] = relevance["min_score"]
          analysis_hash["comment_relevance_top_score"] = relevance["top_relevance_score"]
          analysis_hash["comment_relevance_ranking"] = Array(relevance["ranked_suggestions"]).first(8)
        end

        metadata_hash["comment_generation_policy"] = {
          "status" => "blocked",
          "required_signals" => required_signal_keys,
          "missing_signals" => missing,
          "enforce_required_evidence" => enforce_required_evidence?,
          "history_ready" => ActiveModel::Type::Boolean.new.cast(preparation["ready_for_comment_generation"]),
          "history_reason_code" => preparation["reason_code"].to_s.presence,
          "history_reason" => preparation["reason"].to_s.presence,
          "blocked_reason_code" => reason_code.to_s.presence || "missing_required_evidence",
          "blocked_reason" => reason,
          "engagement_classification" => classification,
          "relevance" => relevance_policy_summary(relevance),
          "updated_at" => Time.current.iso8601(3)
        }.compact
        metadata_hash["engagement_classification"] = classification if classification

        post.update!(analysis: analysis_hash, metadata: metadata_hash) if post&.persisted?

        {
          blocked: true,
          status: analysis_hash["comment_generation_status"],
          source: analysis_hash["comment_generation_source"],
          suggestions_count: 0,
          reason_code: reason_code.to_s.presence || "missing_required_evidence",
          history_reason_code: preparation["reason_code"].to_s.presence
        }
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

      private

      attr_reader :post, :required_signal_keys

      def enforce_required_evidence?
        @enforce_required_evidence
      end

      def policy_status(missing_required:, history_pending:)
        return "enabled_with_missing_required_evidence" if missing_required.any?
        return "enabled_history_pending" if history_pending

        "enabled"
      end

      def blocked_reason(missing_signals:, fallback_reason_code:)
        parts = []
        parts << "face_signal_missing" if missing_signals.include?("face")
        parts << "text_context_missing(ocr_or_transcript)" if missing_signals.include?("text_context")
        parts << fallback_reason_code.to_s if parts.empty?
        parts.join(", ")
      end

      def blocked_status_for(reason_code:)
        case reason_code.to_s
        when "unsuitable_for_engagement"
          "blocked_unsuitable_for_engagement"
        when "low_relevance_suggestions"
          "blocked_low_relevance"
        else
          "blocked_missing_required_evidence"
        end
      end

      def normalize_engagement_classification(value)
        row = value.is_a?(Hash) ? value : {}
        return nil if row.empty?

        {
          "content_type" => row["content_type"].to_s.presence || row[:content_type].to_s.presence,
          "ownership" => row["ownership"].to_s.presence || row[:ownership].to_s.presence,
          "same_profile_owner_content" => boolean_value(row, "same_profile_owner_content"),
          "engagement_suitable" => boolean_value(row, "engagement_suitable"),
          "reason_codes" => Array(row["reason_codes"] || row[:reason_codes]).map(&:to_s).map(&:strip).reject(&:blank?).uniq.first(16),
          "summary" => row["summary"].to_s.presence || row[:summary].to_s.presence,
          "content_signal_score" => (row["personal_signal_score"] || row[:personal_signal_score]).to_i,
          "content_signal_threshold" => (row["personal_signal_threshold"] || row[:personal_signal_threshold]).to_i,
          "detected_external_handles" => Array(row["detected_external_handles"] || row[:detected_external_handles]).map(&:to_s).map(&:strip).reject(&:blank?).uniq.first(12),
          "source_owner_username" => row["source_owner_username"].to_s.presence || row[:source_owner_username].to_s.presence,
          "hashtag_count" => (row["hashtag_count"] || row[:hashtag_count]).to_i,
          "mention_count" => (row["mention_count"] || row[:mention_count]).to_i,
          "profile_tags" => Array(row["profile_tags"] || row[:profile_tags]).map(&:to_s).map(&:strip).reject(&:blank?).uniq.first(8)
        }.compact
      end

      def normalize_relevance_evaluation(value)
        row = value.is_a?(Hash) ? value : {}
        return nil if row.empty?

        {
          "min_score" => (row["min_score"] || row[:min_score]).to_f.round(3),
          "required_eligible_count" => (row["required_eligible_count"] || row[:required_eligible_count]).to_i,
          "eligible_count" => (row["eligible_count"] || row[:eligible_count]).to_i,
          "eligible_medium_or_high_count" => (row["eligible_medium_or_high_count"] || row[:eligible_medium_or_high_count]).to_i,
          "quality_gate_passed" => boolean_value(row, "quality_gate_passed"),
          "high_score_override_score" => (row["high_score_override_score"] || row[:high_score_override_score]).to_f.round(3),
          "high_score_override_applied" => boolean_value(row, "high_score_override_applied"),
          "top_relevance_score" => if row["top_relevance_score"].present?
            row["top_relevance_score"].to_f.round(3)
          elsif row[:top_relevance_score].present?
            row[:top_relevance_score].to_f.round(3)
          end,
          "ranked_suggestions" => Array(row["ranked_suggestions"] || row[:ranked_suggestions]).select { |item| item.is_a?(Hash) }.first(8),
          "error_class" => row["error_class"].to_s.presence || row[:error_class].to_s.presence,
          "error_message" => row["error_message"].to_s.presence || row[:error_message].to_s.presence,
          "evaluated_at" => row["evaluated_at"].to_s.presence || row[:evaluated_at].to_s.presence
        }.compact
      end

      def relevance_policy_summary(value)
        row = value.is_a?(Hash) ? value : {}
        return nil if row.empty?

        {
          "min_score" => row["min_score"],
          "required_eligible_count" => row["required_eligible_count"],
          "eligible_count" => row["eligible_count"],
          "eligible_medium_or_high_count" => row["eligible_medium_or_high_count"],
          "quality_gate_passed" => row["quality_gate_passed"],
          "high_score_override_score" => row["high_score_override_score"],
          "high_score_override_applied" => row["high_score_override_applied"],
          "top_relevance_score" => row["top_relevance_score"],
          "evaluated_at" => row["evaluated_at"],
          "error_class" => row["error_class"],
          "error_message" => row["error_message"]
        }.compact
      end

      def boolean_value(row, key)
        return ActiveModel::Type::Boolean.new.cast(row[key]) if row.key?(key)
        return ActiveModel::Type::Boolean.new.cast(row[key.to_sym]) if row.key?(key.to_sym)

        nil
      end

      def normalize_hash(value)
        value.is_a?(Hash) ? value.deep_dup : {}
      end
    end
  end
end
