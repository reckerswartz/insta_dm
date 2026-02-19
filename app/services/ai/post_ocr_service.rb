module Ai
  class PostOcrService
    def initialize(client: Ai::LocalMicroserviceClient.new)
      @client = client
    end

    def extract_from_image_bytes(image_bytes:, usage_context: {})
      return skipped_result(reason: "image_bytes_missing") if image_bytes.blank?

      response = @client.analyze_image_bytes!(
        image_bytes,
        features: [ { type: "TEXT_DETECTION" } ],
        usage_category: "ocr",
        usage_context: usage_context
      )

      rows = Array(response["textAnnotations"])
      blocks = rows.map do |row|
        next unless row.is_a?(Hash)

        text = row["description"].to_s.strip
        next if text.blank?

        {
          "text" => text,
          "confidence" => row["confidence"].to_f,
          "bbox" => normalize_bbox(row.dig("boundingPoly", "vertices")),
          "source" => "ocr"
        }
      end.compact.first(80)

      {
        skipped: false,
        ocr_text: blocks.map { |row| row["text"] }.uniq.join("\n").presence,
        ocr_blocks: blocks,
        metadata: {
          source: "local_microservice_ocr",
          block_count: blocks.length
        }
      }
    rescue StandardError => e
      {
        skipped: true,
        ocr_text: nil,
        ocr_blocks: [],
        metadata: {
          source: "local_microservice_ocr",
          reason: "ocr_error",
          error_class: e.class.name,
          error_message: e.message.to_s
        }
      }
    end

    private

    def skipped_result(reason:)
      {
        skipped: true,
        ocr_text: nil,
        ocr_blocks: [],
        metadata: {
          source: "local_microservice_ocr",
          reason: reason
        }
      }
    end

    def normalize_bbox(vertices)
      points = Array(vertices).map do |row|
        next unless row.is_a?(Hash)

        x = row["x"]
        y = row["y"]
        next if x.nil? || y.nil?

        [ x.to_f, y.to_f ]
      end.compact
      return {} if points.empty?

      xs = points.map(&:first)
      ys = points.map(&:last)
      {
        "x1" => xs.min,
        "y1" => ys.min,
        "x2" => xs.max,
        "y2" => ys.max
      }
    end
  end
end
