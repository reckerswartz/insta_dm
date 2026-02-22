# frozen_string_literal: true

class AnalyzeAiFeatureEvidenceJob < ApplicationJob
  queue_as :maintenance

  def perform(days: nil)
    resolved_days = (days || ENV.fetch("AI_FEATURE_EVIDENCE_DAYS", "14")).to_i
    report = Ops::AiFeatureEvidenceService.new(days: resolved_days).call

    Ops::StructuredLogger.info(
      event: "ai.feature_evidence.snapshot",
      payload: {
        days: report[:days],
        window_start: report[:window_start].iso8601,
        window_end: report[:window_end].iso8601,
        summary: report[:summary],
        rows: report[:rows].map do |row|
          {
            provider: row[:provider],
            operation: row[:operation],
            category: row[:category],
            calls: row[:calls],
            failures: row[:failures],
            failure_ratio: row[:failure_ratio].round(4),
            recommendation: row[:recommendation]
          }
        end
      }
    )
  end
end
