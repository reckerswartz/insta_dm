require "net/http"
require "json"

module Ai
  class OllamaClient
    BASE_URL = ENV.fetch("OLLAMA_URL", "http://localhost:11434").freeze
    DEFAULT_MODEL = ENV.fetch("OLLAMA_MODEL", "mistral:7b").freeze
    
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
    
    def generate(model:, prompt:, temperature: 0.8, max_tokens: 900)
      payload = {
        model: model || @default_model,
        prompt: prompt,
        options: {
          temperature: temperature,
          num_predict: max_tokens
        },
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
    
    def chat(model:, messages:, temperature: 0.8, max_tokens: 900)
      payload = {
        model: model || @default_model,
        messages: messages,
        options: {
          temperature: temperature,
          num_predict: max_tokens
        },
        stream: false
      }
      
      response = post_json("/api/chat", payload)
      
      {
        "model" => response["model"],
        "message" => response["message"],
        "done" => response["done"],
        "prompt_eval_count" => response["prompt_eval_count"],
        "eval_count" => response["eval_count"]
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
    
    def get_json(endpoint)
      uri = URI.parse("#{@base_url}#{endpoint}")
      http = Net::HTTP.new(uri.host, uri.port)
      http.open_timeout = 10
      http.read_timeout = 60
      
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
      http.open_timeout = 10
      http.read_timeout = 120
      
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
