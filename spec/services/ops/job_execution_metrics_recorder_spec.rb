require "rails_helper"

RSpec.describe Ops::JobExecutionMetricsRecorder do
  describe ".record_transition" do
    it "persists terminal transition metrics" do
      payload = {
        transition: "completed",
        sidekiq_jid: "jid_123",
        active_job_id: "active_123",
        provider_job_id: "jid_123",
        sidekiq_class: "ActiveJob::QueueAdapters::SidekiqAdapter::JobWrapper",
        job_class: "GenerateLlmCommentJob",
        queue_name: "ai_llm_comment_queue",
        retry_count: 1,
        queue_wait_ms: 3200,
        processing_duration_ms: 9200,
        total_time_ms: 12_400,
        transition_recorded_at_ms: (Time.current.to_f * 1000).to_i,
        instagram_account_id: 7,
        instagram_profile_id: 11,
        instagram_profile_post_id: 19,
        error_message: nil
      }

      expect do
        described_class.record_transition(payload: payload)
      end.to change(BackgroundJobExecutionMetric, :count).by(1)

      row = BackgroundJobExecutionMetric.order(:id).last
      expect(row.status).to eq("completed")
      expect(row.job_class).to eq("GenerateLlmCommentJob")
      expect(row.queue_name).to eq("ai_llm_comment_queue")
      expect(row.processing_duration_ms).to eq(9200)
      expect(row.queue_wait_ms).to eq(3200)
      expect(row.metadata).to include("error_message" => nil)
    end

    it "ignores non-terminal transitions" do
      payload = {
        transition: "processing",
        active_job_id: "active_123",
        job_class: "GenerateLlmCommentJob",
        queue_name: "ai_llm_comment_queue"
      }

      expect do
        described_class.record_transition(payload: payload)
      end.not_to change(BackgroundJobExecutionMetric, :count)
    end
  end
end
