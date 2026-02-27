# frozen_string_literal: true

module Ai
  module ModelDefaults
    DEFAULT_TEXT_MODEL = "llama3.2:3b".freeze
    DEFAULT_VISION_MODEL = "llama3.2-vision:11b".freeze

    module_function

    def vision_model
      ENV.fetch("OLLAMA_VISION_MODEL", DEFAULT_VISION_MODEL).to_s.presence || DEFAULT_VISION_MODEL
    end

    def base_model
      ENV.fetch("OLLAMA_MODEL", DEFAULT_TEXT_MODEL).to_s.presence || DEFAULT_TEXT_MODEL
    end

    def fast_model
      ENV.fetch("OLLAMA_FAST_MODEL", base_model).to_s.presence || base_model
    end

    def quality_model
      ENV.fetch("OLLAMA_QUALITY_MODEL", fast_model).to_s.presence || fast_model
    end

    def comment_model
      ENV.fetch("OLLAMA_COMMENT_MODEL", fast_model).to_s.presence || fast_model
    end
  end
end
