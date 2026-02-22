require "net/http"
require "json"
require "base64"

module Ai
  class OllamaClient
    BASE_URL = ENV.fetch("OLLAMA_URL", "http://localhost:11434").freeze
    DEFAULT_MODEL = Ai::ModelDefaults.base_model.freeze
    DEFAULT_NUM_CTX = ENV.fetch("OLLAMA_NUM_CTX", "2048").to_i.clamp(1024, 32768)
    DEFAULT_NUM_THREAD = ENV["OLLAMA_NUM_THREAD"].to_i
    OPEN_TIMEOUT_SECONDS = ENV.fetch("OLLAMA_OPEN_TIMEOUT_SECONDS", "12").to_i.clamp(5, 60)
    READ_TIMEOUT_SECONDS = ENV.fetch("OLLAMA_READ_TIMEOUT_SECONDS", "240").to_i.clamp(30, 600)
    
    def initialize(base_url: nil, default_model: nil)
      @base_url = base_url || BASE_URL
      @default_model = default_model || DEFAULT_MODEL
    end
    
    def test_connection!
      response = get_json("/api/tags")
      models = response["models"] || []
      
      {
        ok: true,
        message: "Ollama is available",
        models: models.map { |m| m["name"] },
        default_model: @default_model
      }
    rescue StandardError => e
      { ok: false, message: e.message.to_s }
    end
    
    def generate(model:, prompt:, temperature: 0.8, max_tokens: 900, num_ctx: nil, num_thread: nil)
      payload = {
        model: model || @default_model,
        prompt: prompt,
        options: generation_options(
          temperature: temperature,
          max_tokens: max_tokens,
          num_ctx: num_ctx,
          num_thread: num_thread
        ),
        keep_alive: ENV.fetch("OLLAMA_KEEP_ALIVE", "10m"),
        stream: false
      }
      
      response = post_json("/api/generate", payload)
      
      {
        "model" => response["model"],
        "response" => response["response"],
        "done" => response["done"],
        "prompt_eval_count" => response["prompt_eval_count"],
        "eval_count" => response["eval_count"],
        "total_duration" => response["total_duration"],
        "load_duration" => response["load_duration"]
      }
    end
    
    def chat(model:, messages:, temperature: 0.8, max_tokens: 900, num_ctx: nil, num_thread: nil)
      payload = {
        model: model || @default_model,
        messages: messages,
        options: generation_options(
          temperature: temperature,
          max_tokens: max_tokens,
          num_ctx: num_ctx,
          num_thread: num_thread
        ),
        keep_alive: ENV.fetch("OLLAMA_KEEP_ALIVE", "10m"),
        stream: false
      }
      
      response = post_json("/api/chat", payload)
      
      {
        "model" => response["model"],
        "message" => response["message"],
        "done" => response["done"],
        "prompt_eval_count" => response["prompt_eval_count"],
        "eval_count" => response["eval_count"],
        "total_duration" => response["total_duration"],
        "load_duration" => response["load_duration"]
      }
    end

    def chat_with_images(model:, prompt:, image_bytes_list:, temperature: 0.4, max_tokens: 500, num_ctx: nil, num_thread: nil)
      encoded_images = Array(image_bytes_list).filter_map do |bytes|
        raw = bytes.to_s.b
        next if raw.blank?

        Base64.strict_encode64(raw)
      end

      raise "No image payload provided for multimodal chat" if encoded_images.empty?

      payload = {
        model: model || @default_model,
        messages: [
          {
            role: "user",
            content: prompt.to_s,
            images: encoded_images
          }
        ],
        options: generation_options(
          temperature: temperature,
          max_tokens: max_tokens,
          num_ctx: num_ctx,
          num_thread: num_thread
        ),
        keep_alive: ENV.fetch("OLLAMA_KEEP_ALIVE", "10m"),
        stream: false
      }

      response = post_json("/api/chat", payload)
      {
        "model" => response["model"],
        "message" => response["message"],
        "done" => response["done"],
        "prompt_eval_count" => response["prompt_eval_count"],
        "eval_count" => response["eval_count"],
        "total_duration" => response["total_duration"],
        "load_duration" => response["load_duration"]
      }
    end
    
    def list_models
      response = get_json("/api/tags")
      response["models"] || []
    end
    
    def pull_model(model_name)
      # This would need to be a streaming implementation for real use
      # For now, just trigger the pull
      payload = { name: model_name }
      post_json("/api/pull", payload)
    end
    
    private

    def generation_options(temperature:, max_tokens:, num_ctx:, num_thread:)
      options = {
        temperature: temperature,
        num_predict: max_tokens,
        num_ctx: (num_ctx || DEFAULT_NUM_CTX).to_i.clamp(512, 32768)
      }
      resolved_thread_count = if num_thread.nil?
        DEFAULT_NUM_THREAD
      else
        num_thread.to_i
      end
      if resolved_thread_count.positive?
        options[:num_thread] = resolved_thread_count.clamp(1, 128)
      end
      options
    end
    
    def get_json(endpoint)
      uri = URI.parse("#{@base_url}#{endpoint}")
      http = Net::HTTP.new(uri.host, uri.port)
      http.open_timeout = OPEN_TIMEOUT_SECONDS
      http.read_timeout = [READ_TIMEOUT_SECONDS, 60].min
      
      request = Net::HTTP::Get.new(uri.request_uri)
      request["Accept"] = "application/json"
      
      response = http.request(request)
      body = JSON.parse(response.body.to_s.presence || "{}")
      
      return body if response.is_a?(Net::HTTPSuccess)
      
      error = body["error"].presence || response.body.to_s.byteslice(0, 500)
      raise "Ollama error: HTTP #{response.code} #{response.message} - #{error}"
    rescue JSON::ParserError
      raise "Ollama error: HTTP #{response.code} #{response.message} - #{response.body.to_s.byteslice(0, 500)}"
    end
    
    def post_json(endpoint, payload)
      uri = URI.parse("#{@base_url}#{endpoint}")
      http = Net::HTTP.new(uri.host, uri.port)
      http.open_timeout = OPEN_TIMEOUT_SECONDS
      http.read_timeout = READ_TIMEOUT_SECONDS
      
      request = Net::HTTP::Post.new(uri.request_uri)
      request["Content-Type"] = "application/json"
      request["Accept"] = "application/json"
      request.body = JSON.generate(payload)
      
      response = http.request(request)
      body = JSON.parse(response.body.to_s.presence || "{}")
      
      return body if response.is_a?(Net::HTTPSuccess)
      
      error = body["error"].presence || response.body.to_s.byteslice(0, 500)
      raise "Ollama error: HTTP #{response.code} #{response.message} - #{error}"
    rescue JSON::ParserError
      raise "Ollama error: HTTP #{response.code} #{response.message} - #{response.body.to_s.byteslice(0, 500)}"
    end
  end
end
