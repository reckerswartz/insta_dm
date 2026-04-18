# frozen_string_literal: true

module AiDashboard
  # Service for poking the NVIDIA Build API from the admin dashboard.
  # Phase 10 swapped the Ollama probe for a `list_models!` auth check
  # against the operator's NVIDIA account so operators can verify the
  # credential without enqueuing a full analysis.
  class ServiceTester
    def initialize(service_name:, test_type:)
      @service_name = service_name.to_s
      @test_type = test_type.to_s
    end

    def call
      case @service_name
      when "nvidia"
        test_nvidia_service
      else
        { error: "Unknown service: #{@service_name}. Supported: nvidia." }
      end
    rescue StandardError => e
      { error: e.message }
    end

    def self.test_all_services
      {
        nvidia: new(service_name: "nvidia", test_type: "models").call
      }
    rescue StandardError => e
      { error: "Service testing failed: #{e.message}" }
    end

    private

    def test_nvidia_service
      case @test_type
      when "", "models", "connection"
        return { success: false, error: "No enabled NVIDIA provider row." } unless Ai::ChatClientFactory.nvidia_available?

        setting = AiProviderSetting.for_provider("nvidia").where(enabled: true).where.not(api_key: [nil, ""]).first
        setting ||= AiProviderSetting.for_provider("nvidia").where(enabled: true).first

        response = Ai::NvidiaClient.new(setting: setting).list_models!
        models = Array(response["data"]).map { |row| row["id"].to_s }.reject(&:blank?)

        {
          success: true,
          result: {
            models: models,
            default_model: setting.effective_model
          },
          message: "NVIDIA Build reachable - #{models.length} model(s) available"
        }
      else
        { error: "Unknown test type: #{@test_type}" }
      end
    end
  end
end
