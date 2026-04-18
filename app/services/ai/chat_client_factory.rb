module Ai
  # Selects the Ollama-shaped chat client for the current provider
  # configuration. Since Phase 9 deleted the legacy Ai::Providers::LocalProvider,
  # the factory always returns an Ai::NvidiaOllamaCompatClient -- but the
  # indirection is retained so callers keep working if a future provider
  # re-introduces multiple back-ends, and so we have a single place to
  # raise a clear error when NVIDIA is misconfigured.
  class ChatClientFactory
    class NoProviderAvailable < StandardError; end

    class << self
      def build
        raise NoProviderAvailable, ERROR_MESSAGE unless nvidia_available?

        Ai::NvidiaOllamaCompatClient.new
      end

      # Backwards-compatible probe the Sidekiq registry + health pages use.
      def nvidia_available?
        AiProviderSetting
          .for_provider("nvidia")
          .where(role: %w[text_quality text_fast], enabled: true)
          .any? { |s| s.api_key_present? }
      rescue StandardError
        false
      end

      ERROR_MESSAGE = "No NVIDIA provider row is enabled with an api_key. " \
                      "Configure one via Admin > AI Provider Settings " \
                      "or run `bin/rails ai:nvidia:enable` once a credential " \
                      "key has been added.".freeze
    end
  end
end
