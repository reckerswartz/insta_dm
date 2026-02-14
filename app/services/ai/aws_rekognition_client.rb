require "base64"

begin
  require "aws-sdk-rekognition"
rescue LoadError
  nil
end

module Ai
  class AwsRekognitionClient
    ONE_PIXEL_PNG_BASE64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO7X6XQAAAAASUVORK5CYII=".freeze

    def initialize(access_key_id:, secret_access_key:, region:, instagram_account_id: nil)
      raise "aws-sdk-rekognition gem is not installed" unless defined?(Aws::Rekognition::Client)
      raise "Missing AWS access key id" if access_key_id.to_s.blank?
      raise "Missing AWS secret access key" if secret_access_key.to_s.blank?
      raise "Missing AWS region" if region.to_s.blank?
      @instagram_account_id = instagram_account_id

      @client = Aws::Rekognition::Client.new(
        access_key_id: access_key_id,
        secret_access_key: secret_access_key,
        region: region
      )
    end

    def test_key!
      detect_labels!(
        bytes: Base64.decode64(ONE_PIXEL_PNG_BASE64),
        max_labels: 1,
        usage_category: "healthcheck",
        usage_context: { workflow: "aws_rekognition_test_key" }
      )
      { ok: true, message: "API key is valid." }
    end

    def detect_labels!(bytes:, max_labels: 15, usage_category: "image_analysis", usage_context: nil)
      started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      begin
        result = @client.detect_labels(image: { bytes: bytes }, max_labels: max_labels).to_h
        Ai::ApiUsageTracker.track_success(
          provider: "aws_rekognition",
          operation: "rekognition.detect_labels",
          category: usage_category,
          started_at: started_at,
          instagram_account_id: @instagram_account_id,
          request_units: 1,
          metadata: { max_labels: max_labels }.merge(usage_context.to_h)
        )
        result
      rescue StandardError => e
        Ai::ApiUsageTracker.track_failure(
          provider: "aws_rekognition",
          operation: "rekognition.detect_labels",
          category: usage_category,
          started_at: started_at,
          instagram_account_id: @instagram_account_id,
          request_units: 1,
          metadata: { max_labels: max_labels }.merge(usage_context.to_h),
          error: e
        )
        raise
      end
    end
  end
end
