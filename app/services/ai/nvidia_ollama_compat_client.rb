module Ai
  # Drop-in replacement for Ai::OllamaClient that routes calls through
  # Ai::Providers::NvidiaProvider. Presents the Ollama-shaped API so the
  # existing comment generators (Ai::LocalEngagementCommentGenerator,
  # Ai::PostCommentGenerationService, LlmComment::EventGenerationPipeline)
  # can be switched onto NVIDIA without changing their prompt-engineering
  # code.
  #
  # Model name mapping
  # ------------------
  # Ollama models are identified by strings like "llama3.2:3b" (fast) or
  # "llama3.2:3b-quality" (quality). We infer which NVIDIA role to use
  # from whether the requested Ollama model matches the "quality" defaults
  # in Ai::ModelDefaults; everything else routes through text_fast.
  # Callers can override by setting env overrides on the role rows or by
  # passing model: "role:<role_name>" to force a specific role.
  class NvidiaOllamaCompatClient
    DEFAULT_TEMPERATURE = 0.7

    def initialize(provider: nil)
      @provider = provider
    end

    def test_connection!
      provider.test_key!
    rescue StandardError => e
      { ok: false, message: e.message.to_s }
    end

    # Ollama signature: generate(model:, prompt:, temperature:, max_tokens:, num_ctx:, num_thread:, format:)
    # Ollama return shape: { "model", "response", "done", "prompt_eval_count", "eval_count", ... }
    def generate(model:, prompt:, temperature: DEFAULT_TEMPERATURE, max_tokens: 900, num_ctx: nil, num_thread: nil, format: nil)
      role = role_for(model)
      opts = {
        temperature: clamp_temperature(temperature),
        max_tokens: max_tokens
      }
      opts[:response_format] = { "type" => "json_object" } if format.to_s.downcase == "json"

      raw = provider.chat!(
        role: role,
        messages: [{ role: "user", content: prompt.to_s }],
        **opts
      )

      content = raw.dig("choices", 0, "message", "content").to_s
      usage = raw["usage"].is_a?(Hash) ? raw["usage"] : {}
      {
        "model" => raw["model"] || Ai::NvidiaModelRouter.model_for(role),
        "response" => content,
        "done" => true,
        "prompt_eval_count" => usage["prompt_tokens"],
        "eval_count" => usage["completion_tokens"],
        "total_duration" => nil,
        "load_duration" => nil
      }
    end

    # Ollama chat signature: chat(model:, messages:, ...)
    # Ollama return shape: { "model", "message" => { "role", "content" }, "done", ... }
    def chat(model:, messages:, temperature: DEFAULT_TEMPERATURE, max_tokens: 900, num_ctx: nil, num_thread: nil)
      role = role_for(model)
      raw = provider.chat!(
        role: role,
        messages: messages,
        temperature: clamp_temperature(temperature),
        max_tokens: max_tokens
      )

      message = raw.dig("choices", 0, "message") || {}
      {
        "model" => raw["model"] || Ai::NvidiaModelRouter.model_for(role),
        "message" => {
          "role" => message["role"] || "assistant",
          "content" => message["content"].to_s
        },
        "done" => true
      }
    end

    private

    def provider
      @provider ||= Ai::ProviderRegistry.build_provider("nvidia")
    end

    # Heuristics for mapping Ollama model strings to NVIDIA role names.
    def role_for(model)
      token = model.to_s.strip.downcase
      return "text_quality" if token.empty?

      # Explicit override: model: "role:text_quality" etc.
      if token.start_with?("role:")
        role = token.split(":", 2).last
        return AiProviderSetting::ROLES.include?(role) ? role : "text_quality"
      end

      # Route Ollama vision models through vision_primary.
      return "vision_primary" if token.include?("vision")

      # Explicit "quality" marker in the model string wins.
      return "text_quality" if token.include?("quality")

      # If ops configured a distinct OLLAMA_QUALITY_MODEL (different from
      # the base), route exact matches of that value through text_quality.
      # When QUALITY==BASE (the default), this check is skipped so the
      # same string isn't ambiguous.
      base = Ai::ModelDefaults.base_model.to_s.downcase
      quality = Ai::ModelDefaults.quality_model.to_s.downcase
      comment_quality = ENV.fetch("OLLAMA_COMMENT_QUALITY_MODEL", "").downcase
      return "text_quality" if !quality.empty? && quality != base && token == quality
      return "text_quality" if !comment_quality.empty? && comment_quality != base && token == comment_quality

      # Default: speed-oriented generations go through text_fast.
      "text_fast"
    end

    def clamp_temperature(value)
      Float(value).clamp(0.0, 2.0)
    rescue StandardError
      DEFAULT_TEMPERATURE
    end
  end
end
