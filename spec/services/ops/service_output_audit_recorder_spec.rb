require "rails_helper"

RSpec.describe Ops::ServiceOutputAuditRecorder do
  describe ".record!" do
    it "records produced, persisted, referenced, and unused keys" do
      before_state = {
        "analysis" => {
          "topics" => [ "old" ]
        },
        "metadata" => {
          "video_processing" => {
            "mode" => "old"
          }
        }
      }
      after_state = {
        "analysis" => {
          "topics" => [ "old", "new" ],
          "video_topics" => [ "new" ]
        },
        "metadata" => {
          "video_processing" => {
            "mode" => "lightweight_v1",
            "cache_hit" => false
          }
        }
      }
      produced = {
        processing_mode: "lightweight_v1",
        topics: [ "new" ],
        transcript: "hello world",
        ignored_field: "unused"
      }
      referenced = {
        processing_mode: "lightweight_v1",
        transcript_present: true
      }

      row = described_class.record!(
        service_name: "PostVideoContextExtractionService",
        execution_source: "ProcessPostVideoAnalysisJob",
        status: "completed",
        run_id: "run-1",
        active_job_id: "job-1",
        queue_name: "ai_video_queue",
        produced: produced,
        referenced: referenced,
        persisted_before: before_state,
        persisted_after: after_state,
        context: {
          instagram_account: 5,
          instagram_profile: 7,
          instagram_profile_post: 9
        },
        metadata: {
          step: "video"
        }
      )

      expect(row).to be_present
      expect(row.service_name).to eq("PostVideoContextExtractionService")
      expect(row.execution_source).to eq("ProcessPostVideoAnalysisJob")
      expect(row.produced_count).to be >= 4
      expect(row.persisted_paths).to include("analysis.video_topics", "metadata.video_processing.mode")
      expect(row.referenced_paths).to include("processing_mode", "transcript_present")
      expect(row.unused_leaf_keys).to include("ignored_field")
      expect(row.unused_count).to be >= 1
      expect(row.instagram_account_id).to eq(5)
      expect(row.instagram_profile_id).to eq(7)
      expect(row.instagram_profile_post_id).to eq(9)
    end

    it "normalizes unsupported status to unknown" do
      row = described_class.record!(
        service_name: "AnyService",
        status: "weird_status",
        produced: { value: 1 },
        referenced: {}
      )

      expect(row.status).to eq("unknown")
    end
  end
end
