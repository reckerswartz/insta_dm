module Ai
  # Selects the appropriate Ollama-shaped chat client for the current
  # provider configuration. When any NVIDIA row is enabled (and has a
  # key), returns an Ai::NvidiaOllamaCompatClient that forwards calls
  # to NVIDIA Build via Ai::Providers::NvidiaProvider#chat!. Otherwise
  # returns an Ai::OllamaClient configured against the legacy local
  # Ollama service.
  #
  # Callers that previously hard-coded `Ai::OllamaClient.new` should use
  # `Ai::ChatClientFactory.build` so they inherit NVIDIA routing
  # automatically. The returned client is duck-typed against the Ollama
  # surface the generators already consume (generate(model:, prompt:,
  # ...) -> { "model", "response", ... }; chat(model:, messages:, ...)
  # -> { "model", "message" => { "role", "content" }, ... }), so no
  # other code changes when the provider switches.
  class ChatClientFactory
    class << self
      def build
        if nvidia_available?
          Ai::NvidiaOllamaCompatClient.new
        else
          Ai::OllamaClient.new
        end
      end

      def nvidia_available?
        AiProviderSetting
          .for_provider("nvidia")
          .where(role: %w[text_quality text_fast], enabled: true)
          .any? { |s| s.api_key_present? }
      rescue StandardError
        false
      end
    end
  end
end
