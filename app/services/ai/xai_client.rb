require "net/http"
require "json"

module Ai
  class XaiClient
    API_BASE = "https://api.x.ai/v1".freeze

    def initialize(api_key: nil, instagram_account_id: nil)
      @api_key = api_key || Rails.application.credentials.dig(:xai, :api_key).to_s
      @instagram_account_id = instagram_account_id
      raise "Missing xAI API key (credentials.xai.api_key)" if @api_key.blank?
    end

    # Uses xAI's OpenAI-compatible legacy Chat Completions endpoint.
    # https://docs.x.ai/docs/api-reference#legacy-chat-completions
    def chat_completions!(model:, messages:, temperature: 0.2, max_tokens: nil, usage_category: "text_generation", usage_context: nil)
      uri = URI.parse("#{API_BASE}/chat/completions")

      payload = {
        model: model,
        messages: messages,
        temperature: temperature
      }
      payload[:max_tokens] = max_tokens if max_tokens.present?

      started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      res = nil
      begin
        res = http_post_json(uri, payload)
        body = JSON.parse(res.body.to_s)

        usage = body["usage"].is_a?(Hash) ? body["usage"] : {}
        Ai::ApiUsageTracker.track_success(
          provider: "xai",
          operation: "chat.completions",
          category: usage_category,
          started_at: started_at,
          instagram_account_id: @instagram_account_id,
          http_status: res.code.to_i,
          request_units: 1,
          input_tokens: usage["prompt_tokens"],
          output_tokens: usage["completion_tokens"],
          total_tokens: usage["total_tokens"],
          metadata: {
            model: model.to_s,
            temperature: temperature,
            max_tokens: max_tokens
          }.merge(usage_context.to_h)
        )
      rescue StandardError => e
        Ai::ApiUsageTracker.track_failure(
          provider: "xai",
          operation: "chat.completions",
          category: usage_category,
          started_at: started_at,
          instagram_account_id: @instagram_account_id,
          http_status: res&.code,
          request_units: 1,
          metadata: {
            model: model.to_s,
            temperature: temperature,
            max_tokens: max_tokens
          }.merge(usage_context.to_h),
          error: e
        )
        raise
      end

      content =
        body.dig("choices", 0, "message", "content").to_s

      {
        raw: body,
        content: content
      }
    end

    private

    def http_post_json(uri, payload)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = (uri.scheme == "https")
      http.open_timeout = 10
      http.read_timeout = 60

      req = Net::HTTP::Post.new(uri.request_uri)
      req["Authorization"] = "Bearer #{@api_key}"
      req["Content-Type"] = "application/json"
      req["Accept"] = "application/json"
      req.body = JSON.generate(payload)

      res = http.request(req)
      return res if res.is_a?(Net::HTTPSuccess)

      raise "xAI API error: HTTP #{res.code} #{res.message} - #{res.body.to_s.byteslice(0, 600)}"
    end
  end
end
