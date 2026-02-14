require "net/http"
require "json"
require "base64"

module Ai
  class AzureVisionClient
    ONE_PIXEL_PNG_BASE64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO7X6XQAAAAASUVORK5CYII=".freeze

    def initialize(api_key:, endpoint:, api_version: "2024-02-01", instagram_account_id: nil)
      @api_key = api_key.to_s
      @endpoint = endpoint.to_s.sub(%r{/\z}, "")
      @api_version = api_version.to_s.presence || "2024-02-01"
      @instagram_account_id = instagram_account_id
      raise "Missing Azure Vision API key" if @api_key.blank?
      raise "Missing Azure Vision endpoint" if @endpoint.blank?
    end

    def test_key!
      analyze_image_bytes!(
        Base64.decode64(ONE_PIXEL_PNG_BASE64),
        features: %w[tags caption],
        usage_category: "healthcheck",
        usage_context: { workflow: "azure_vision_test_key" }
      )
      { ok: true, message: "API key is valid." }
    end

    def analyze_image_url!(url, features:, usage_category: "image_analysis", usage_context: nil)
      uri = analysis_uri(features: features)
      post_json(
        uri: uri,
        payload: { url: url.to_s },
        headers: { "Content-Type" => "application/json" },
        tracking: {
          category: usage_category,
          request_units: 1,
          metadata: { features: Array(features), source: "url" }.merge(usage_context.to_h)
        }
      )
    end

    def analyze_image_bytes!(bytes, features:, usage_category: "image_analysis", usage_context: nil)
      uri = analysis_uri(features: features)
      post_raw(
        uri: uri,
        bytes: bytes,
        headers: { "Content-Type" => "application/octet-stream" },
        tracking: {
          category: usage_category,
          request_units: 1,
          metadata: { features: Array(features), source: "bytes" }.merge(usage_context.to_h)
        }
      )
    end

    private

    def analysis_uri(features:)
      features_list = Array(features).join(",")
      URI.parse("#{@endpoint}/computervision/imageanalysis:analyze?api-version=#{@api_version}&features=#{features_list}&language=en&gender-neutral-caption=true")
    end

    def post_json(uri:, payload:, headers:, tracking: nil)
      post_raw(uri: uri, bytes: JSON.generate(payload), headers: headers, tracking: tracking)
    end

    def post_raw(uri:, bytes:, headers:, tracking: nil)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true
      http.open_timeout = 10
      http.read_timeout = 90

      req = Net::HTTP::Post.new(uri.request_uri)
      req["Ocp-Apim-Subscription-Key"] = @api_key
      req["Accept"] = "application/json"
      headers.each { |k, v| req[k] = v }
      req.body = bytes

      started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      res = nil
      begin
        res = http.request(req)
        body = parse_response!(res)
        track_success(tracking: tracking, started_at: started_at, http_status: res.code.to_i)
        body
      rescue StandardError => e
        track_failure(tracking: tracking, started_at: started_at, http_status: res&.code, error: e)
        raise
      end
    end

    def parse_response!(res)
      body = JSON.parse(res.body.to_s.presence || "{}")
      return body if res.is_a?(Net::HTTPSuccess)

      message = body["message"].presence || body.dig("error", "message").presence || res.body.to_s.byteslice(0, 500)
      raise "Azure Vision API error: HTTP #{res.code} #{res.message} - #{message}"
    rescue JSON::ParserError
      raise "Azure Vision API error: HTTP #{res.code} #{res.message} - #{res.body.to_s.byteslice(0, 500)}"
    end

    def track_success(tracking:, started_at:, http_status:)
      return unless tracking.is_a?(Hash)

      Ai::ApiUsageTracker.track_success(
        provider: "azure_vision",
        operation: "computervision.imageanalysis.analyze",
        category: tracking[:category],
        started_at: started_at,
        instagram_account_id: @instagram_account_id,
        http_status: http_status,
        request_units: tracking[:request_units],
        metadata: tracking[:metadata] || {}
      )
    end

    def track_failure(tracking:, started_at:, http_status:, error:)
      return unless tracking.is_a?(Hash)

      Ai::ApiUsageTracker.track_failure(
        provider: "azure_vision",
        operation: "computervision.imageanalysis.analyze",
        category: tracking[:category],
        started_at: started_at,
        instagram_account_id: @instagram_account_id,
        http_status: http_status,
        request_units: tracking[:request_units],
        metadata: tracking[:metadata] || {},
        error: error
      )
    end
  end
end
