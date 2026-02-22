require "rails_helper"

RSpec.describe Ops::QueueProcessingEstimator do
  describe ".snapshot" do
    it "combines live queue depth with DB timing samples" do
      now = Time.current
      8.times do |idx|
        BackgroundJobExecutionMetric.create!(
          active_job_id: "job_#{idx}",
          provider_job_id: "jid_#{idx}",
          sidekiq_jid: "jid_#{idx}",
          job_class: "GenerateLlmCommentJob",
          queue_name: "ai_llm_comment_queue",
          status: "completed",
          queue_wait_ms: 500 + (idx * 50),
          processing_duration_ms: 1500 + (idx * 100),
          total_time_ms: 2200 + (idx * 150),
          recorded_at: now - idx.minutes
        )
      end

      queue = instance_double(Sidekiq::Queue, name: "ai_llm_comment_queue", size: 5, latency: 3.25)
      process = { "queues" => [ "ai_llm_comment_queue" ], "concurrency" => 2 }
      process_set = [ process ]

      allow(Sidekiq::Queue).to receive(:all).and_return([ queue ])
      allow(Sidekiq::ProcessSet).to receive(:new).and_return(process_set)

      snapshot = described_class.snapshot(backend: "sidekiq", queue_names: [ "ai_llm_comment_queue" ], use_cache: false)
      row = snapshot[:estimates].first

      expect(snapshot[:backend]).to eq("sidekiq")
      expect(snapshot[:queue_count]).to eq(1)
      expect(row[:queue_name]).to eq("ai_llm_comment_queue")
      expect(row[:queue_size]).to eq(5)
      expect(row[:estimated_concurrency]).to eq(2.0)
      expect(row[:sample_size]).to eq(8)
      expect(row[:median_processing_ms]).to be > 0
      expect(row[:estimated_new_item_total_seconds]).to be > 0
      expect(row[:estimated_queue_drain_seconds]).to be > 0
    end

    it "returns an empty snapshot when backend is not sidekiq" do
      snapshot = described_class.snapshot(backend: "solid_queue", use_cache: false)

      expect(snapshot).to include(
        backend: "solid_queue",
        queue_count: 0,
        queued_items_total: 0
      )
      expect(snapshot[:estimates]).to eq([])
    end
  end
end
