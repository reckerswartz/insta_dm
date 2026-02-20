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
        history_pending:
      )
        analysis_hash = normalize_hash(analysis)
        metadata_hash = normalize_hash(metadata)

        analysis_hash["comment_suggestions"] = suggestions
        analysis_hash["comment_generation_status"] = generation_result[:status].to_s.presence || "ok"
        analysis_hash["comment_generation_source"] = generation_result[:source].to_s.presence || "ollama"
        analysis_hash["comment_generation_fallback_used"] = ActiveModel::Type::Boolean.new.cast(generation_result[:fallback_used])
        analysis_hash["comment_generation_error"] = generation_result[:error_message].to_s.presence

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
          "updated_at" => Time.current.iso8601(3)
        }.compact

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

      def persist_blocked!(analysis:, metadata:, preparation:, missing_signals:, reason_code:, error_message: nil)
        analysis_hash = normalize_hash(analysis)
        metadata_hash = normalize_hash(metadata)
        missing = Array(missing_signals).map(&:to_s).map(&:strip).reject(&:blank?).uniq
        reason = blocked_reason(missing_signals: missing, fallback_reason_code: reason_code)

        analysis_hash["comment_suggestions"] = []
        analysis_hash["comment_generation_status"] = "blocked_missing_required_evidence"
        analysis_hash["comment_generation_source"] = "policy"
        analysis_hash["comment_generation_fallback_used"] = false
        analysis_hash["comment_generation_error"] = error_message.to_s.presence || reason

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
          "updated_at" => Time.current.iso8601(3)
        }.compact

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

      def normalize_hash(value)
        value.is_a?(Hash) ? value.deep_dup : {}
      end
    end
  end
end
