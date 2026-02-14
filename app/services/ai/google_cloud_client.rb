require "net/http"
require "json"
require "base64"

module Ai
  class GoogleCloudClient
    VISION_BASE = "https://vision.googleapis.com/v1".freeze
    VIDEO_BASE = "https://videointelligence.googleapis.com/v1".freeze
    GEMINI_BASE = "https://generativelanguage.googleapis.com/v1beta".freeze
    ONE_PIXEL_PNG_BASE64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO7X6XQAAAAASUVORK5CYII=".freeze

    def initialize(api_key: nil, instagram_account_id: nil)
      @api_key = api_key.to_s
      @instagram_account_id = instagram_account_id
      raise "Missing Google Cloud API key" if @api_key.blank?
    end

    def test_key!
      analyze_image_bytes!(
        Base64.decode64(ONE_PIXEL_PNG_BASE64),
        features: [ { type: "LABEL_DETECTION", maxResults: 1 } ],
        usage_category: "healthcheck",
        usage_context: { workflow: "google_cloud_test_key" }
      )
      { ok: true, message: "API key is valid." }
    end

    def analyze_image_bytes!(bytes, features:, usage_category: "image_analysis", usage_context: nil)
      payload = {
        requests: [
          {
            image: { content: Base64.strict_encode64(bytes) },
            features: features
          }
        ]
      }

      body = post_json(
        "#{VISION_BASE}/images:annotate?key=#{@api_key}",
        payload,
        tracking: {
          provider: "google_cloud",
          operation: "vision.images.annotate",
          category: usage_category,
          instagram_account_id: @instagram_account_id,
          request_units: 1,
          metadata: { features: Array(features).map { |f| f[:type] || f["type"] }.compact.uniq, source: "bytes" }.merge(usage_context.to_h)
        }
      )
      body.dig("responses", 0) || {}
    end

    def analyze_image_uri!(url, features:, usage_category: "image_analysis", usage_context: nil)
      payload = {
        requests: [
          {
            image: { source: { imageUri: url.to_s } },
            features: features
          }
        ]
      }

      body = post_json(
        "#{VISION_BASE}/images:annotate?key=#{@api_key}",
        payload,
        tracking: {
          provider: "google_cloud",
          operation: "vision.images.annotate",
          category: usage_category,
          instagram_account_id: @instagram_account_id,
          request_units: 1,
          metadata: { features: Array(features).map { |f| f[:type] || f["type"] }.compact.uniq, source: "uri" }.merge(usage_context.to_h)
        }
      )
      body.dig("responses", 0) || {}
    end

    def analyze_video_bytes!(bytes, features:, usage_context: nil)
      payload = {
        inputContent: Base64.strict_encode64(bytes),
        features: features,
        videoContext: {
          labelDetectionConfig: {
            labelDetectionMode: "SHOT_MODE"
          }
        }
      }

      post_json(
        "#{VIDEO_BASE}/videos:annotate?key=#{@api_key}",
        payload,
        tracking: {
          provider: "google_cloud",
          operation: "videointelligence.videos.annotate",
          category: "video_analysis",
          instagram_account_id: @instagram_account_id,
          request_units: 1,
          metadata: { features: Array(features).map(&:to_s).uniq }.merge(usage_context.to_h)
        }
      )
    end

    def fetch_video_operation!(name, usage_context: nil)
      get_json(
        "#{VIDEO_BASE}/#{name}?key=#{@api_key}",
        tracking: {
          provider: "google_cloud",
          operation: "videointelligence.operations.get",
          category: "video_analysis",
          instagram_account_id: @instagram_account_id,
          request_units: 1,
          metadata: { operation_name: name.to_s }.merge(usage_context.to_h)
        }
      )
    end

    def generate_text_json!(model:, prompt:, temperature: 0.8, max_output_tokens: 900, usage_category: "text_generation", usage_context: nil)
      model_name = model.to_s.strip
      raise "Missing Google text model" if model_name.blank?

      payload = {
        contents: [
          {
            role: "user",
            parts: [
              { text: prompt.to_s }
            ]
          }
        ],
        generationConfig: {
          temperature: temperature,
          maxOutputTokens: max_output_tokens,
          responseMimeType: "application/json"
        }
      }

      body = post_json(
        "#{GEMINI_BASE}/models/#{model_name}:generateContent?key=#{@api_key}",
        payload,
        tracking: {
          provider: "google_cloud",
          operation: "gemini.generate_content",
          category: usage_category,
          instagram_account_id: @instagram_account_id,
          request_units: 1,
          metadata: { model: model_name, max_output_tokens: max_output_tokens, temperature: temperature }.merge(usage_context.to_h)
        }
      )
      text =
        body.dig("candidates", 0, "content", "parts", 0, "text").to_s
      raise "Google text model returned empty response" if text.blank?

      parsed = JSON.parse(text) rescue nil
      usage = body["usageMetadata"].is_a?(Hash) ? body["usageMetadata"] : {}
      {
        raw: body,
        text: text,
        json: parsed,
        usage: {
          input_tokens: usage["promptTokenCount"],
          output_tokens: usage["candidatesTokenCount"],
          total_tokens: usage["totalTokenCount"]
        }
      }
    end

    private

    def post_json(url, payload, tracking: nil)
      uri = URI.parse(url)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true
      http.open_timeout = 10
      http.read_timeout = 90

      req = Net::HTTP::Post.new(uri.request_uri)
      req["Content-Type"] = "application/json"
      req["Accept"] = "application/json"
      req.body = JSON.generate(payload)

      started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      res = nil
      begin
        res = http.request(req)
        body = parse_response!(res)
        track_success(tracking: tracking, started_at: started_at, http_status: res.code.to_i, response_body: body)
        body
      rescue StandardError => e
        track_failure(tracking: tracking, started_at: started_at, http_status: res&.code, error: e)
        raise
      end
    end

    def get_json(url, tracking: nil)
      uri = URI.parse(url)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true
      http.open_timeout = 10
      http.read_timeout = 30

      req = Net::HTTP::Get.new(uri.request_uri)
      req["Accept"] = "application/json"
      started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      res = nil
      begin
        res = http.request(req)
        body = parse_response!(res)
        track_success(tracking: tracking, started_at: started_at, http_status: res.code.to_i, response_body: body)
        body
      rescue StandardError => e
        track_failure(tracking: tracking, started_at: started_at, http_status: res&.code, error: e)
        raise
      end
    end

    def parse_response!(res)
      body = JSON.parse(res.body.to_s.presence || "{}")
      return body if res.is_a?(Net::HTTPSuccess)

      err = body.dig("error", "message").presence || res.body.to_s.byteslice(0, 500)
      raise "Google Cloud API error: HTTP #{res.code} #{res.message} - #{err}"
    rescue JSON::ParserError
      raise "Google Cloud API error: HTTP #{res.code} #{res.message} - #{res.body.to_s.byteslice(0, 500)}"
    end

    def track_success(tracking:, started_at:, http_status:, response_body:)
      return unless tracking.is_a?(Hash)

      usage = response_body.is_a?(Hash) ? (response_body["usageMetadata"] || {}) : {}
      Ai::ApiUsageTracker.track_success(
        provider: tracking[:provider],
        operation: tracking[:operation],
        category: tracking[:category],
        started_at: started_at,
        instagram_account_id: tracking[:instagram_account_id],
        http_status: http_status,
        request_units: tracking[:request_units],
        input_tokens: usage["promptTokenCount"],
        output_tokens: usage["candidatesTokenCount"],
        total_tokens: usage["totalTokenCount"],
        metadata: tracking[:metadata] || {}
      )
    end

    def track_failure(tracking:, started_at:, http_status:, error:)
      return unless tracking.is_a?(Hash)

      Ai::ApiUsageTracker.track_failure(
        provider: tracking[:provider],
        operation: tracking[:operation],
        category: tracking[:category],
        started_at: started_at,
        instagram_account_id: tracking[:instagram_account_id],
        http_status: http_status,
        request_units: tracking[:request_units],
        metadata: tracking[:metadata] || {},
        error: error
      )
    end
  end
end
