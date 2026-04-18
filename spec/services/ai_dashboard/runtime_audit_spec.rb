require "rails_helper"

RSpec.describe AiDashboard::RuntimeAudit do
  it "builds concurrent lane summary and cleanup candidates using the NVIDIA service_status shape" do
    allow(Ops::QueueProcessingEstimator).to receive(:snapshot).and_return(
      {
        estimates: [
          {
            queue_name: "ai_llm_comment_queue",
            estimated_new_item_total_seconds: 35.5,
            estimated_queue_drain_seconds: 88.0,
            confidence: "medium",
            sample_size: 12
          }
        ]
      }
    )

    # Phase 10 swapped the service_status payload from an Ollama health
    # probe to an NVIDIA Build API probe. RuntimeAudit now reads
    # details[:nvidia][:models] and policy[:execution_mode] = "nvidia_build".
    service_status = {
      status: "online",
      details: {
        nvidia: {
          ok: true,
          models: [
            "meta/llama-3.3-70b-instruct",
            "meta/llama-3.2-11b-vision-instruct",
            "some-other-model"
          ]
        },
        policy: {
          execution_mode: "nvidia_build"
        }
      }
    }
    queue_metrics = {
      backend: "sidekiq",
      services: [
        {
          service_key: "legacy_ai_default",
          queue_pending: 0,
          api_calls_24h: 0
        },
        {
          service_key: "llm_comment_generation",
          queue_pending: 2,
          api_calls_24h: 14,
          recent_failures_24h: 1
        }
      ]
    }

    result = described_class.new(
      service_status: service_status,
      queue_metrics: queue_metrics
    ).call

    expect(result[:queue_backend]).to eq("sidekiq")
    expect(result.dig(:architecture, :execution_mode)).to eq("nvidia_build")
    expect(result.dig(:architecture, :nvidia_ok)).to eq(true)
    expect(result.dig(:architecture, :nvidia_available_models)).to include(
      "meta/llama-3.3-70b-instruct",
      "meta/llama-3.2-11b-vision-instruct"
    )
    expect(result.dig(:totals, :total_lanes).to_i).to be > 0
    expect(result[:host_services].map { |row| row[:service_key] }).not_to include("ollama")
    expect(result[:concurrent_services]).to include(
      hash_including(service_key: "llm_comment_generation", queue_pending: 2)
    )
    llm_row = result[:concurrent_services].find { |row| row[:service_key] == "llm_comment_generation" }
    expect(llm_row).to include(
      eta_new_item_seconds: 35.5,
      eta_queue_drain_seconds: 88.0,
      eta_confidence: "medium"
    )
    # Phase 10 removed the "unused_ollama_models" cleanup candidate since
    # NVIDIA models are cloud-hosted.
    expect(result[:cleanup_candidates].map { |row| row[:id] }).not_to include("unused_ollama_models")
  end
end
