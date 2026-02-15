class FaceDetectionService
  def initialize(client: nil)
    @client = client || build_local_client
  end

  def detect(media_payload:)
    bytes = media_payload[:image_bytes]
    return empty_result(reason: "image_bytes_missing") if bytes.blank?
    return empty_result(reason: "local_client_unavailable") unless @client

    response = @client.detect_faces_and_ocr!(
      image_bytes: bytes,
      usage_context: {
        workflow: "story_processing",
        story_id: media_payload[:story_id].to_s
      }
    )
    parse_response(response)
  rescue StandardError => e
    empty_result(reason: "vision_error", error_message: e.message)
  end

  private

  def build_local_client
    Ai::LocalMicroserviceClient.new
  rescue StandardError
    nil
  end

  def parse_response(response)
    text = response.dig("ocr_text").to_s
    location_tags = Array(response.dig("location_tags") || []).map(&:to_s).reject(&:blank?).uniq
    content_labels = Array(response.dig("content_labels") || []).map(&:to_s).downcase.strip.reject(&:blank?).uniq
    mentions = text.scan(/@[a-zA-Z0-9._]+/).map(&:downcase).uniq
    hashtags = text.scan(/#[a-zA-Z0-9_]+/).map(&:downcase).uniq

    {
      faces: Array(response.dig("faces") || []).map { |face| normalize_face(face) },
      ocr_text: text.presence,
      location_tags: location_tags.first(20),
      content_signals: content_labels.first(30),
      mentions: mentions.first(30),
      hashtags: hashtags.first(30),
      metadata: {
        source: "local_ai",
        face_count: Array(response.dig("faces") || []).length
      }
    }
  end

  def normalize_face(face)
    {
      confidence: face.dig("confidence").to_f,
      bounding_box: face.dig("bounding_box") || {},
      landmarks: Array(face.dig("landmarks") || []).first(12).map do |item|
        {
          type: item.dig("type").to_s,
          x: item.dig("x"),
          y: item.dig("y"),
          z: item.dig("z")
        }
      end,
      likelihoods: face.dig("likelihoods") || {}
    }
  end

  def empty_result(reason:, error_message: nil)
    {
      faces: [],
      ocr_text: nil,
      location_tags: [],
      content_signals: [],
      mentions: [],
      hashtags: [],
      metadata: {
        source: "local_ai",
        reason: reason,
        error_message: error_message.to_s.presence
      }.compact
    }
  end
end
