# frozen_string_literal: true

module Ai
  module ModelDefaults
    META_LLAMA_3_2_VISION = "llama3.2-vision:11b".freeze

    module_function

    def vision_model
      ENV.fetch("OLLAMA_VISION_MODEL", META_LLAMA_3_2_VISION).to_s.presence || META_LLAMA_3_2_VISION
    end

    def base_model
      ENV.fetch("OLLAMA_MODEL", vision_model).to_s.presence || vision_model
    end

    def fast_model
      ENV.fetch("OLLAMA_FAST_MODEL", base_model).to_s.presence || base_model
    end

    def quality_model
      ENV.fetch("OLLAMA_QUALITY_MODEL", base_model).to_s.presence || fast_model
    end

    def comment_model
      ENV.fetch("OLLAMA_COMMENT_MODEL", fast_model).to_s.presence || fast_model
    end
  end
end
