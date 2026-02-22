require "rails_helper"

RSpec.describe AiDashboard::RuntimeAudit do
  it "builds concurrent lane summary and cleanup candidates" do
    service_status = {
      status: "online",
      details: {
        microservice: {
          ok: true,
          services: {
            "vision" => true,
            "face" => true
          }
        },
        ollama: {
          ok: true,
          models: [
            Ai::ModelDefaults.base_model,
            Ai::ModelDefaults.vision_model,
            "unused-model:1b"
          ]
        },
        policy: {
          microservice_enabled: true,
          microservice_required: false
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
    expect(result.dig(:totals, :total_lanes).to_i).to be > 0
    expect(result[:concurrent_services]).to include(
      hash_including(service_key: "llm_comment_generation", queue_pending: 2)
    )
    expect(result[:cleanup_candidates]).to include(
      hash_including(id: "unused_ollama_models", status: "safe_to_remove")
    )
  end
end
