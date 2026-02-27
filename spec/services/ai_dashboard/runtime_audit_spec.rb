require "rails_helper"

RSpec.describe AiDashboard::RuntimeAudit do
  it "builds concurrent lane summary and cleanup candidates" do
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

    service_status = {
      status: "online",
      details: {
        ollama: {
          ok: true,
          models: [
            Ai::ModelDefaults.base_model,
            Ai::ModelDefaults.vision_model,
            "unused-model:1b"
          ]
        },
        policy: {
          execution_mode: "ollama_only"
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
    expect(result.dig(:architecture, :execution_mode)).to eq("ollama_only")
    expect(result.dig(:totals, :total_lanes).to_i).to be > 0
    expect(result[:host_services]).not_to include(hash_including(service_key: "local_microservice"))
    expect(result[:concurrent_services]).to include(
      hash_including(service_key: "llm_comment_generation", queue_pending: 2)
    )
    llm_row = result[:concurrent_services].find { |row| row[:service_key] == "llm_comment_generation" }
    expect(llm_row).to include(
      eta_new_item_seconds: 35.5,
      eta_queue_drain_seconds: 88.0,
      eta_confidence: "medium"
    )
    expect(result[:cleanup_candidates]).to include(
      hash_including(id: "unused_ollama_models", status: "safe_to_remove")
    )
  end
end
