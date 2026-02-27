# frozen_string_literal: true

module AiDashboard
  # Service for testing local AI runtime endpoints.
  class ServiceTester
    def initialize(service_name:, test_type:)
      @service_name = service_name.to_s
      @test_type = test_type.to_s
    end

    def call
      case @service_name
      when "ollama"
        test_ollama_service
      else
        { error: "Unknown service: #{@service_name}" }
      end
    rescue StandardError => e
      { error: e.message }
    end

    def self.test_all_services
      {
        ollama: new(service_name: "ollama", test_type: "models").call
      }
    rescue StandardError => e
      { error: "Service testing failed: #{e.message}" }
    end

    private

    def test_ollama_service(test_type = @test_type)
      case test_type
      when "", "models", "connection"
        payload = Ai::OllamaClient.new.test_connection!
        ok = extract_ok(payload)
        return { success: false, error: payload_message(payload) } unless ok

        models = Array(payload_value(payload, :models))
        default_model = payload_value(payload, :default_model).to_s

        {
          success: true,
          result: {
            models: models,
            default_model: default_model
          },
          message: "Ollama reachable - #{models.length} model(s) available"
        }
      else
        { error: "Unknown test type: #{test_type}" }
      end
    end

    def extract_ok(payload)
      ActiveModel::Type::Boolean.new.cast(payload_value(payload, :ok))
    end

    def payload_message(payload)
      payload_value(payload, :message).to_s.presence || "Ollama unavailable"
    end

    def payload_value(payload, key)
      return nil unless payload.is_a?(Hash)

      payload[key] || payload[key.to_s]
    end
  end
end
