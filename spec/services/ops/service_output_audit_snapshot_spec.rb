require "rails_helper"

RSpec.describe Ops::ServiceOutputAuditSnapshot do
  describe ".snapshot" do
    it "aggregates service audit rows and top unused keys" do
      now = Time.current

      ServiceOutputAudit.create!(
        service_name: "PostVideoContextExtractionService",
        execution_source: "ProcessPostVideoAnalysisJob",
        status: "completed",
        run_id: "run-1",
        active_job_id: "job-1",
        queue_name: "ai_video_queue",
        produced_count: 10,
        referenced_count: 3,
        persisted_count: 4,
        unused_count: 3,
        produced_paths: %w[processing_mode topics transcript ignored_field],
        produced_leaf_keys: %w[processing_mode topics transcript ignored_field],
        referenced_paths: %w[processing_mode transcript_present],
        persisted_paths: %w[analysis.video_topics metadata.video_processing.mode],
        unused_leaf_keys: %w[ignored_field transcript],
        metadata: { step: "video" },
        recorded_at: now
      )

      ServiceOutputAudit.create!(
        service_name: "PostVideoContextExtractionService",
        execution_source: "ProcessPostVideoAnalysisJob",
        status: "failed",
        run_id: "run-2",
        active_job_id: "job-2",
        queue_name: "ai_video_queue",
        produced_count: 6,
        referenced_count: 1,
        persisted_count: 1,
        unused_count: 4,
        produced_paths: %w[processing_mode topics error_message ignored_field],
        produced_leaf_keys: %w[processing_mode topics error_message ignored_field],
        referenced_paths: %w[processing_mode],
        persisted_paths: %w[metadata.video_processing.reason],
        unused_leaf_keys: %w[ignored_field error_message],
        metadata: { step: "video" },
        recorded_at: now
      )

      ServiceOutputAudit.create!(
        service_name: "Ai::PostOcrService",
        execution_source: "ProcessPostOcrAnalysisJob",
        status: "completed",
        run_id: "run-3",
        active_job_id: "job-3",
        queue_name: "ai_ocr_queue",
        produced_count: 5,
        referenced_count: 2,
        persisted_count: 2,
        unused_count: 1,
        produced_paths: %w[ocr_text ocr_blocks metadata.source],
        produced_leaf_keys: %w[ocr_text ocr_blocks source],
        referenced_paths: %w[text_present ocr_blocks_count],
        persisted_paths: %w[analysis.ocr_text metadata.ocr_analysis.source],
        unused_leaf_keys: %w[source],
        metadata: { step: "ocr" },
        recorded_at: now
      )

      snapshot = described_class.snapshot(window_hours: 24, service_limit: 10, key_limit: 10, use_cache: false)

      expect(snapshot[:total_rows]).to eq(3)
      expect(snapshot[:completed_rows]).to eq(2)
      expect(snapshot[:failed_rows]).to eq(1)
      expect(snapshot[:unique_services]).to eq(2)

      video_row = snapshot[:services].find { |row| row[:service_name] == "PostVideoContextExtractionService" }
      expect(video_row).to be_present
      expect(video_row[:executions]).to eq(2)
      expect(video_row[:failed]).to eq(1)
      expect(video_row[:avg_unused_count]).to be > 0
      expect(Array(video_row[:top_unused_keys]).map { |row| row[:key] }).to include("ignored_field")

      top_unused_keys = Array(snapshot[:top_unused_leaf_keys]).map { |row| row[:key] }
      expect(top_unused_keys).to include("ignored_field")
    end
  end
end
