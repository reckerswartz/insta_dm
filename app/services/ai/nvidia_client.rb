require "net/http"
require "uri"
require "json"

module Ai
  # Thin OpenAI-compatible client for NVIDIA Build
  # (https://integrate.api.nvidia.com/v1/).
  #
  # Stateless; accepts a model string on every call so callers can pick
  # per-role models via Ai::NvidiaModelRouter. Instantiate with a specific
  # AiProviderSetting to inherit its base_url / api_key / timeout / RPM, or
  # with explicit kwargs to override.
  class NvidiaClient
    class Error < StandardError; end
    class TransientError < Error; end
    class RateLimitError < TransientError; end
    class AuthError < Error; end
    class InvalidResponseError < Error; end
    class ConfigurationError < Error; end

    DEFAULT_BASE_URL = "https://integrate.api.nvidia.com/v1".freeze
    DEFAULT_OPEN_TIMEOUT_SECONDS = 15
    DEFAULT_READ_TIMEOUT_SECONDS = 120
    DEFAULT_MAX_RETRIES = 3
    BACKOFF_BASE_SECONDS = 0.75
    BACKOFF_MAX_SECONDS = 12.0

    RETRYABLE_STATUS = [408, 409, 425, 429, 500, 502, 503, 504].freeze

    attr_reader :base_url, :open_timeout_seconds, :read_timeout_seconds

    def initialize(
      api_key: nil,
      base_url: nil,
      open_timeout_seconds: nil,
      read_timeout_seconds: nil,
      max_retries: DEFAULT_MAX_RETRIES,
      setting: nil,
      rate_limiter: nil,
      logger: Rails.logger
    )
      @setting = setting
      @api_key = (api_key.presence || setting&.effective_api_key).to_s
      @base_url = (base_url.presence || setting&.effective_base_url.presence || DEFAULT_BASE_URL).chomp("/")
      @open_timeout_seconds = (open_timeout_seconds || DEFAULT_OPEN_TIMEOUT_SECONDS).to_i
      @read_timeout_seconds = (read_timeout_seconds || setting&.request_timeout_seconds || DEFAULT_READ_TIMEOUT_SECONDS).to_i
      @max_retries = max_retries.to_i.clamp(0, 8)
      @rate_limiter = rate_limiter
      @logger = logger
    end

    # Returns the parsed /v1/models list. Cheapest auth check.
    def list_models!
      request_json!(:get, "/models")
    end

    # OpenAI-compatible chat completion.
    # messages: Array of { role: "user"|"system"|"assistant", content: String | Array<Hash> }
    # Vision: content can be [ { type: "text", text: "..." }, { type: "image_url", image_url: { url: "data:..." } } ]
    def chat!(model:, messages:, temperature: nil, max_tokens: nil, top_p: nil, stream: false, extra: {})
      raise ConfigurationError, "chat streaming is not supported yet" if stream

      body = {
        model: model,
        messages: messages,
        stream: false
      }
      body[:temperature] = temperature unless temperature.nil?
      body[:max_tokens] = max_tokens unless max_tokens.nil?
      body[:top_p] = top_p unless top_p.nil?
      body.merge!(extra.compact) if extra.is_a?(Hash)

      request_json!(:post, "/chat/completions", body: body)
    end

    # OpenAI-compatible embeddings.
    # input: String | Array<String>. NVIDIA embedding NIMs also require
    # `input_type` ("query" | "passage") which callers can pass via `extra`.
    def embed!(model:, input:, extra: {})
      body = { model: model, input: Array(input) }
      body.merge!(extra.compact) if extra.is_a?(Hash)

      request_json!(:post, "/embeddings", body: body)
    end

    # Convenience: encode binary image bytes as an OpenAI-style image_url
    # data URL usable inside a chat `messages` content array.
    def self.image_data_url(bytes:, mime_type: "image/jpeg")
      "data:#{mime_type};base64,#{Base64.strict_encode64(bytes)}"
    end

    private

    attr_reader :setting, :api_key, :max_retries, :rate_limiter, :logger

    def request_json!(method, path, body: nil)
      raise AuthError, "NVIDIA api_key is not configured" if api_key.blank?

      uri = URI.join("#{base_url}/", path.to_s.sub(%r{\A/}, ""))
      attempt = 0

      begin
        attempt += 1
        rate_limiter&.throttle!(setting: setting)

        response = http_perform(method, uri, body)
        status = response.code.to_i

        return parse_success(response) if status.between?(200, 299)

        handle_error!(response, status)
      rescue TransientError => e
        raise if attempt > max_retries

        sleep(backoff(attempt, retry_after: e.respond_to?(:retry_after) ? e.retry_after : nil))
        retry
      rescue Net::OpenTimeout, Net::ReadTimeout, Errno::ECONNRESET, Errno::ECONNREFUSED, SocketError, EOFError => e
        raise TransientError, "NVIDIA transport error: #{e.class}: #{e.message}" if attempt > max_retries

        sleep(backoff(attempt))
        retry
      end
    end

    def http_perform(method, uri, body)
      request =
        case method
        when :get  then Net::HTTP::Get.new(uri)
        when :post then Net::HTTP::Post.new(uri)
        else raise ConfigurationError, "unsupported method #{method}"
        end

      request["Authorization"] = "Bearer #{api_key}"
      request["Accept"] = "application/json"
      if body
        request["Content-Type"] = "application/json"
        request.body = JSON.generate(body)
      end

      Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https",
                                          open_timeout: open_timeout_seconds,
                                          read_timeout: read_timeout_seconds) do |http|
        http.request(request)
      end
    end

    def parse_success(response)
      return {} if response.body.to_s.empty?

      JSON.parse(response.body)
    rescue JSON::ParserError => e
      raise InvalidResponseError, "NVIDIA returned non-JSON body: #{e.message}: #{response.body.to_s[0, 200]}"
    end

    def handle_error!(response, status)
      body_excerpt = response.body.to_s[0, 500]
      message = "NVIDIA API error status=#{status} body=#{body_excerpt}"

      if status == 401 || status == 403
        raise AuthError, message
      elsif status == 429
        retry_after = response["retry-after"].to_f
        err = RateLimitError.new(message)
        err.define_singleton_method(:retry_after) { retry_after }
        raise err
      elsif RETRYABLE_STATUS.include?(status)
        raise TransientError, message
      else
        raise Error, message
      end
    end

    def backoff(attempt, retry_after: nil)
      return retry_after.clamp(0.1, BACKOFF_MAX_SECONDS) if retry_after && retry_after.positive?

      jitter = rand(0.0..0.25)
      [BACKOFF_BASE_SECONDS * (2**(attempt - 1)) + jitter, BACKOFF_MAX_SECONDS].min
    end
  end
end
