require "rails_helper"

RSpec.describe InstagramAccounts::LlmQueueInspector do
  describe "#queue_estimate" do
    it "returns DB-backed estimate when available" do
      inspector = described_class.new

      allow(Ops::QueueProcessingEstimator).to receive(:estimate_for_queue).and_return(
        {
          queue_name: "ai_llm_comment_queue",
          queue_size: 4,
          estimated_new_item_wait_seconds: 12.2,
          estimated_new_item_total_seconds: 30.5,
          estimated_queue_drain_seconds: 88.7,
          confidence: "medium",
          sample_size: 20
        }
      )

      payload = inspector.queue_estimate
      expect(payload).to include(
        queue_name: "ai_llm_comment_queue",
        queue_size: 4,
        estimated_new_item_total_seconds: 30.5,
        confidence: "medium",
        sample_size: 20
      )
    end

    it "falls back to queue-size heuristic when estimate is unavailable" do
      inspector = described_class.new
      allow(Ops::QueueProcessingEstimator).to receive(:estimate_for_queue).and_return(nil)
      allow(inspector).to receive(:queue_size).and_return(3)

      payload = inspector.queue_estimate
      expect(payload[:queue_size]).to eq(3)
      expect(payload[:estimated_new_item_total_seconds]).to be > 0
      expect(payload[:confidence]).to eq("low")
      expect(payload[:sample_size]).to eq(0)
    end
  end
end
