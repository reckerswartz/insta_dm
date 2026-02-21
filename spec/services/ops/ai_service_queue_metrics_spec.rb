require "rails_helper"
require "securerandom"

RSpec.describe Ops::AiServiceQueueMetrics do
  describe ".snapshot" do
    before do
      allow(Ops::LiveUpdateBroadcaster).to receive(:broadcast!)
    end

    it "aggregates queue depth, failures, and API usage per AI service" do
      profile_queue = instance_double(Sidekiq::Queue, name: "ai_profile_analysis_queue", size: 3)
      comment_queue = instance_double(Sidekiq::Queue, name: "ai_comment_generation_queue", size: 2)
      visual_queue = instance_double(Sidekiq::Queue, name: "ai_visual_queue", size: 1)

      allow(profile_queue).to receive(:first).and_return([ instance_double("Sidekiq::JobRecord", klass: "AnalyzeInstagramProfileJob") ])
      allow(comment_queue).to receive(:first).and_return([ instance_double("Sidekiq::JobRecord", klass: "GeneratePostCommentSuggestionsJob") ])
      allow(visual_queue).to receive(:first).and_return([ instance_double("Sidekiq::JobRecord", klass: "ProcessPostVisualAnalysisJob") ])
      allow(Sidekiq::Queue).to receive(:all).and_return([ profile_queue, comment_queue, visual_queue ])

      AiApiCall.create!(
        provider: "local",
        operation: "analyze_profile",
        category: "image_analysis",
        status: "succeeded",
        latency_ms: 120,
        total_tokens: 80,
        occurred_at: 5.minutes.ago,
        metadata: {
          "queue_name" => "ai_profile_analysis_queue",
          "job_class" => "AnalyzeInstagramProfileJob"
        }
      )

      AiApiCall.create!(
        provider: "local",
        operation: "generate_post_comments",
        category: "text_generation",
        status: "failed",
        latency_ms: 300,
        total_tokens: 110,
        occurred_at: 4.minutes.ago,
        metadata: {
          "queue_name" => "ai_comment_generation_queue",
          "job_class" => "GeneratePostCommentSuggestionsJob"
        }
      )

      BackgroundJobFailure.create!(
        active_job_id: "job_#{SecureRandom.hex(4)}",
        queue_name: "ai_profile_analysis_queue",
        job_class: "AnalyzeInstagramProfileJob",
        error_class: "StandardError",
        error_message: "failed profile analysis",
        failure_kind: "runtime",
        retryable: true,
        occurred_at: 8.minutes.ago,
        metadata: {}
      )

      snapshot = described_class.snapshot(backend: "sidekiq")
      profile_row = snapshot[:services].find { |row| row[:service_key] == "profile_analysis_runner" }
      comment_row = snapshot[:services].find { |row| row[:service_key] == "post_comment_generation" }

      expect(snapshot[:backend]).to eq("sidekiq")
      expect(snapshot[:queue_pending_total]).to be >= 6
      expect(profile_row).to include(
        queue_pending: 3,
        recent_failures_24h: 1,
        api_calls_24h: 1,
        api_failed_calls_24h: 0
      )
      expect(profile_row[:api_avg_latency_ms_24h]).to eq(120.0)
      expect(comment_row).to include(
        queue_pending: 2,
        api_calls_24h: 1,
        api_failed_calls_24h: 1
      )
      expect(comment_row[:sampled_job_classes]).to include(
        hash_including(key: "GeneratePostCommentSuggestionsJob", count: 1)
      )
    end
  end
end
