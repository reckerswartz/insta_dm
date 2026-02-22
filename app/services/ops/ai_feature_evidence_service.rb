# frozen_string_literal: true

module Ops
  class AiFeatureEvidenceService
    TARGETS = [
      { provider: "local_microservice", operation: "detect_faces_and_ocr", category: "image_analysis" },
      { provider: "local_microservice", operation: "analyze_video_story_intelligence", category: "video_analysis" },
      { provider: "local_microservice", operation: "analyze_video_bytes", category: "video_analysis" },
      { provider: "local_microservice", operation: "transcribe_audio", category: "other" },
      { provider: "local_whisper_binary", operation: "transcribe_audio", category: "other" }
    ].freeze

    def initialize(days: 14)
      @days = days.to_i.clamp(1, 120)
    end

    def call
      window_start = @days.days.ago
      rows = TARGETS.map do |target|
        build_row(target: target, window_start: window_start)
      end

      {
        days: @days,
        window_start: window_start,
        window_end: Time.current,
        rows: rows,
        summary: {
          total_calls: rows.sum { |row| row[:calls].to_i },
          remove_candidates: rows.count { |row| row[:recommendation] == "remove_candidate_no_usage" },
          improve_candidates: rows.count { |row| row[:recommendation] == "improve_candidate_high_failure" },
          keep_candidates: rows.count { |row| row[:recommendation] == "keep_active" }
        }
      }
    end

    private

    def build_row(target:, window_start:)
      scope = AiApiCall
        .where(provider: target[:provider], operation: target[:operation], category: target[:category])
        .where("occurred_at >= ?", window_start)

      total = scope.count
      failures = scope.where(status: "failed").count
      failure_ratio = total.positive? ? (failures.to_f / total.to_f) : 0.0

      {
        provider: target[:provider],
        operation: target[:operation],
        category: target[:category],
        calls: total,
        failures: failures,
        failure_ratio: failure_ratio,
        recommendation: recommendation_for(total: total, failures: failures)
      }
    end

    def recommendation_for(total:, failures:)
      return "remove_candidate_no_usage" if total.to_i.zero?

      failure_ratio = total.to_i.positive? ? (failures.to_f / total.to_f) : 0.0
      return "improve_candidate_high_failure" if total.to_i >= 10 && failure_ratio >= 0.40

      "keep_active"
    end
  end
end
