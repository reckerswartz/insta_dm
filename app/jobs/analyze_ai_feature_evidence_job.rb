# frozen_string_literal: true

class AnalyzeAiFeatureEvidenceJob < ApplicationJob
  queue_as :maintenance

  # Accept both positional-hash and keyword-arg forms. Sidekiq-cron serialises
  # `args: [{ days: 14 }]` through ActiveJob without `_aj_symbol_keys`, which
  # lands as a positional Hash rather than kwargs under Ruby ≥ 3.0 kwarg
  # separation rules. Without this shim the job retries forever with
  # `ArgumentError: wrong number of arguments (given 1, expected 0)`.
  def perform(opts_or_days = nil, days: nil)
    days_input =
      case opts_or_days
      when Hash
        opts_or_days[:days] || opts_or_days["days"] || days
      when Numeric, String
        opts_or_days
      else
        days
      end

    resolved_days = (days_input || ENV.fetch("AI_FEATURE_EVIDENCE_DAYS", "14")).to_i
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
