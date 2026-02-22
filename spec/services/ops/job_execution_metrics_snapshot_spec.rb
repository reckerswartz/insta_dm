require "rails_helper"

RSpec.describe Ops::JobExecutionMetricsSnapshot do
  describe ".snapshot" do
    it "builds queue-level timing aggregates" do
      now = Time.current

      3.times do |idx|
        BackgroundJobExecutionMetric.create!(
          active_job_id: "complete_#{idx}",
          provider_job_id: "jid_complete_#{idx}",
          sidekiq_jid: "jid_complete_#{idx}",
          job_class: "AnalyzeInstagramPostJob",
          queue_name: "ai_post_analysis_queue",
          status: "completed",
          queue_wait_ms: 100 + (idx * 20),
          processing_duration_ms: 400 + (idx * 50),
          total_time_ms: 800 + (idx * 80),
          recorded_at: now - idx.minutes
        )
      end

      BackgroundJobExecutionMetric.create!(
        active_job_id: "failed_1",
        provider_job_id: "jid_failed_1",
        sidekiq_jid: "jid_failed_1",
        job_class: "AnalyzeInstagramPostJob",
        queue_name: "ai_post_analysis_queue",
        status: "failed",
        queue_wait_ms: 120,
        processing_duration_ms: 500,
        total_time_ms: 900,
        recorded_at: now
      )

      snapshot = described_class.snapshot(window_hours: 24, queue_limit: 10, use_cache: false)
      queue_row = snapshot[:queues].find { |row| row[:queue_name] == "ai_post_analysis_queue" }

      expect(snapshot[:total_rows]).to eq(4)
      expect(snapshot[:completed_rows]).to eq(3)
      expect(snapshot[:failed_rows]).to eq(1)
      expect(snapshot[:avg_processing_ms]).to be > 0
      expect(queue_row).to include(
        queue_name: "ai_post_analysis_queue",
        total_rows: 4,
        completed_rows: 3,
        failed_rows: 1
      )
      expect(queue_row[:median_processing_ms]).to be > 0
      expect(queue_row[:p90_processing_ms]).to be > 0
    end
  end
end
