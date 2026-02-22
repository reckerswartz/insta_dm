# frozen_string_literal: true

require "json"

module Ai
  class VisionUnderstandingService
    DEFAULT_MODEL = Ai::ModelDefaults.vision_model.freeze
    MAX_IMAGES = ENV.fetch("OLLAMA_VISION_MAX_IMAGES", "2").to_i.clamp(1, 8)
    MAX_IMAGE_BYTES = ENV.fetch("OLLAMA_VISION_MAX_IMAGE_BYTES", (4 * 1024 * 1024).to_s).to_i.clamp(64 * 1024, 16 * 1024 * 1024)
    TOPIC_LIMIT = ENV.fetch("OLLAMA_VISION_TOPIC_LIMIT", "18").to_i.clamp(6, 60)
    OBJECT_LIMIT = ENV.fetch("OLLAMA_VISION_OBJECT_LIMIT", "18").to_i.clamp(6, 60)
    SUMMARY_MAX_CHARS = ENV.fetch("OLLAMA_VISION_SUMMARY_MAX_CHARS", "220").to_i.clamp(80, 700)

    def initialize(ollama_client: Ai::OllamaClient.new, model: nil, enabled: nil)
      @ollama_client = ollama_client
      @model = model.to_s.presence || DEFAULT_MODEL
      @enabled = enabled.nil? ? default_enabled? : ActiveModel::Type::Boolean.new.cast(enabled)
    end

    def enabled?
      @enabled
    end

    def summarize(image_bytes_list:, transcript: nil, candidate_topics: [], media_type: "video")
      return unavailable(reason: "vision_understanding_disabled") unless @enabled

      normalized_images = normalize_images(image_bytes_list)
      return unavailable(reason: "vision_images_missing") if normalized_images.empty?

      prompt = build_prompt(
        media_type: media_type,
        transcript: transcript,
        candidate_topics: candidate_topics
      )
      chat_result = chat_with_supported_image_count(
        model: @model,
        prompt: prompt,
        image_bytes_list: normalized_images
      )
      response = chat_result[:response]
      message_text = response.dig("message", "content").to_s
      parsed = parse_json_payload(message_text)
      summary = truncate_text(parsed["summary"].to_s, max: SUMMARY_MAX_CHARS)
      summary = truncate_text(message_text, max: SUMMARY_MAX_CHARS) if summary.blank?

      topics = normalize_keywords(parsed["topics"], limit: TOPIC_LIMIT)
      objects = normalize_keywords(parsed["objects"], limit: OBJECT_LIMIT)
      visual_cues = normalize_keywords(parsed["visual_cues"], limit: OBJECT_LIMIT)

      {
        ok: summary.present? || topics.any? || objects.any? || visual_cues.any?,
        model: response["model"].to_s.presence || @model,
        summary: summary.presence,
        topics: normalize_keywords(Array(candidate_topics) + topics + objects + visual_cues, limit: TOPIC_LIMIT),
        objects: normalize_keywords(objects + visual_cues, limit: OBJECT_LIMIT),
        raw: response,
        metadata: {
          status: "completed",
          source: "ollama_vision",
          model: response["model"].to_s.presence || @model,
          prompt_eval_count: response["prompt_eval_count"].to_i,
          eval_count: response["eval_count"].to_i,
          total_duration_ns: response["total_duration"].to_i,
          load_duration_ns: response["load_duration"].to_i,
          images_used: chat_result[:images_used].to_i,
          single_image_retry: ActiveModel::Type::Boolean.new.cast(chat_result[:single_image_retry]),
          retry_reason: chat_result[:retry_reason].to_s.presence
        }.compact
      }
    rescue StandardError => e
      unavailable(reason: "vision_model_error", error_class: e.class.name, error_message: e.message)
    end

    private

    def default_enabled?
      fallback = if defined?(Rails) && Rails.respond_to?(:env) && Rails.env.test?
        "false"
      else
        "true"
      end
      ActiveModel::Type::Boolean.new.cast(ENV.fetch("OLLAMA_VISION_UNDERSTANDING_ENABLED", fallback))
    end

    def normalize_images(image_bytes_list)
      Array(image_bytes_list).filter_map do |row|
        bytes = row.to_s.b
        next if bytes.blank?
        next if bytes.bytesize > MAX_IMAGE_BYTES

        bytes
      end.first(MAX_IMAGES)
    end

    def chat_with_supported_image_count(model:, prompt:, image_bytes_list:)
      response = chat_with_images(
        model: model,
        prompt: prompt,
        image_bytes_list: image_bytes_list
      )
      {
        response: response,
        images_used: image_bytes_list.length,
        single_image_retry: false
      }
    rescue StandardError => e
      raise unless image_bytes_list.length > 1 && single_image_model_error?(e)

      fallback_images = image_bytes_list.first(1)
      response = chat_with_images(
        model: model,
        prompt: prompt,
        image_bytes_list: fallback_images
      )
      {
        response: response,
        images_used: fallback_images.length,
        single_image_retry: true,
        retry_reason: "model_single_image_limit"
      }
    end

    def chat_with_images(model:, prompt:, image_bytes_list:)
      @ollama_client.chat_with_images(
        model: model,
        prompt: prompt,
        image_bytes_list: image_bytes_list,
        temperature: 0.2,
        max_tokens: 260
      )
    end

    def single_image_model_error?(error)
      message = error.message.to_s.downcase
      return false if message.blank?

      message.include?("only supports one image") ||
        (message.include?("one image") && message.include?("more than one image")) ||
        message.include?("more than one image requested")
    end

    def build_prompt(media_type:, transcript:, candidate_topics:)
      hints = Array(candidate_topics).map(&:to_s).map(&:strip).reject(&:blank?).uniq.first(8)
      transcript_text = truncate_text(transcript.to_s, max: 140)

      <<~PROMPT
        Analyze the attached #{media_type} frame(s) for Instagram-safe visual understanding.
        Return strict JSON only with keys:
        - summary (string, <= #{SUMMARY_MAX_CHARS} chars)
        - topics (array of short lowercase tokens)
        - objects (array of short lowercase tokens)
        - visual_cues (array of short lowercase phrases)

        Requirements:
        - Use only what is visible in the frames
        - Do not infer sensitive attributes
        - Keep terms concrete and comment-safe
        - Avoid repeating the same token across arrays

        Candidate hints: #{JSON.generate(hints)}
        Transcript hint (may be empty): #{JSON.generate(transcript_text)}
      PROMPT
    end

    def parse_json_payload(text)
      raw = text.to_s
      return {} if raw.blank?

      JSON.parse(raw)
    rescue JSON::ParserError
      left = raw.index("{")
      right = raw.rindex("}")
      return {} unless left && right && right > left

      JSON.parse(raw[left..right])
    rescue StandardError
      {}
    end

    def normalize_keywords(values, limit:)
      Array(values)
        .map(&:to_s)
        .map { |value| value.downcase.strip }
        .reject(&:blank?)
        .map { |value| value.gsub(/[^\p{Alnum}\s_#@-]/, "").strip }
        .reject(&:blank?)
        .uniq
        .first(limit)
    end

    def truncate_text(value, max:)
      text = value.to_s.strip
      return text if text.length <= max

      "#{text.byteslice(0, max)}..."
    end

    def unavailable(reason:, error_class: nil, error_message: nil)
      {
        ok: false,
        model: @model,
        summary: nil,
        topics: [],
        objects: [],
        raw: {},
        metadata: {
          status: "unavailable",
          source: "ollama_vision",
          model: @model,
          reason: reason.to_s,
          error_class: error_class.to_s.presence,
          error_message: error_message.to_s.presence
        }.compact
      }
    end
  end
end
