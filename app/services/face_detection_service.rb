class FaceDetectionService
  GOOGLE_FEATURES = [
    { type: "FACE_DETECTION", maxResults: 16 },
    { type: "TEXT_DETECTION", maxResults: 10 },
    { type: "LANDMARK_DETECTION", maxResults: 10 },
    { type: "LABEL_DETECTION", maxResults: 20 }
  ].freeze

  def initialize(client: nil)
    @client = client || build_google_client
  end

  def detect(media_payload:)
    bytes = media_payload[:image_bytes]
    return empty_result(reason: "image_bytes_missing") if bytes.blank?
    return empty_result(reason: "google_client_unavailable") unless @client

    response = @client.analyze_image_bytes!(
      bytes,
      features: GOOGLE_FEATURES,
      usage_category: "story_face_ocr",
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

  def build_google_client
    setting = AiProviderSetting.find_by(provider: "google_cloud")
    key = setting&.effective_api_key.to_s.presence || Rails.application.credentials.dig(:google_cloud, :api_key).to_s
    return nil if key.blank?

    Ai::GoogleCloudClient.new(api_key: key)
  rescue StandardError
    nil
  end

  def parse_response(response)
    text = response.dig("fullTextAnnotation", "text").to_s
    if text.blank?
      text = Array(response["textAnnotations"]).first.to_h["description"].to_s
    end

    location_tags = Array(response["landmarkAnnotations"]).map { |item| item["description"].to_s.strip }.reject(&:blank?).uniq
    content_labels = Array(response["labelAnnotations"]).map { |item| item["description"].to_s.downcase.strip }.reject(&:blank?).uniq
    mentions = text.scan(/@[a-zA-Z0-9._]+/).map(&:downcase).uniq
    hashtags = text.scan(/#[a-zA-Z0-9_]+/).map(&:downcase).uniq

    {
      faces: Array(response["faceAnnotations"]).map { |face| normalize_face(face) },
      ocr_text: text.presence,
      location_tags: location_tags.first(20),
      content_signals: content_labels.first(30),
      mentions: mentions.first(30),
      hashtags: hashtags.first(30),
      metadata: {
        source: "google_vision",
        face_count: Array(response["faceAnnotations"]).length
      }
    }
  end

  def normalize_face(face)
    {
      confidence: face["detectionConfidence"].to_f,
      bounding_box: bounding_box_hash(face),
      landmarks: Array(face["landmarks"]).first(12).map do |item|
        {
          type: item["type"].to_s,
          x: item.dig("position", "x"),
          y: item.dig("position", "y"),
          z: item.dig("position", "z")
        }
      end,
      likelihoods: {
        joy: face["joyLikelihood"].to_s,
        sorrow: face["sorrowLikelihood"].to_s,
        anger: face["angerLikelihood"].to_s,
        surprise: face["surpriseLikelihood"].to_s,
        blurred: face["blurredLikelihood"].to_s,
        headwear: face["headwearLikelihood"].to_s
      }
    }
  end

  def bounding_box_hash(face)
    vertices = Array(face.dig("boundingPoly", "vertices").presence || face.dig("fdBoundingPoly", "vertices"))
    xs = vertices.map { |v| v["x"].to_f }
    ys = vertices.map { |v| v["y"].to_f }
    return {} if xs.empty? || ys.empty?

    left = xs.min
    right = xs.max
    top = ys.min
    bottom = ys.max

    {
      left: left.round(2),
      top: top.round(2),
      width: (right - left).round(2),
      height: (bottom - top).round(2)
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
        source: "google_vision",
        reason: reason,
        error_message: error_message.to_s.presence
      }.compact
    }
  end
end
