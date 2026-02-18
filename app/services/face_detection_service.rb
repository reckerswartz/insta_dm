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
    payload = response.is_a?(Hash) ? response : {}
    nested = payload["results"].is_a?(Hash) ? payload["results"] : {}

    text_from_payload = payload.dig("ocr_text").to_s
    text_from_nested = Array(nested["text"]).map { |row| row.is_a?(Hash) ? row["text"].to_s : row.to_s }.map(&:strip).reject(&:blank?).uniq.join("\n")
    text = [text_from_payload, text_from_nested].map(&:strip).reject(&:blank?).join("\n").presence
    ocr_blocks = normalize_ocr_blocks(payload: payload, nested: nested)

    location_tags = Array(payload.dig("location_tags") || []).map(&:to_s).map(&:strip).reject(&:blank?).uniq
    content_labels = (
      Array(payload.dig("content_labels")) +
      Array(nested["labels"]).map { |row| row.is_a?(Hash) ? (row["label"] || row["description"]) : row }
    ).map { |value| value.to_s.downcase.strip }.reject(&:blank?).uniq
    object_detections = normalize_object_detections(payload: payload, nested: nested)
    scenes = Array(payload.dig("scenes") || nested["scenes"]).map do |row|
      next unless row.is_a?(Hash)
      {
        timestamp: row["timestamp"] || row[:timestamp],
        type: (row["type"] || row[:type]).to_s.presence || "scene_change",
        correlation: row["correlation"] || row[:correlation]
      }.compact
    end.compact.first(80)

    mentions = (
      Array(payload.dig("mentions")) +
      text.to_s.scan(/@[a-zA-Z0-9._]+/)
    ).map(&:to_s).map(&:downcase).uniq
    profile_handles = (
      Array(payload.dig("profile_handles")) +
      text.to_s.scan(/\b[a-zA-Z0-9._]{3,30}\b/)
    ).map(&:to_s)
      .map(&:downcase)
      .select { |token| token.include?("_") || token.include?(".") }
      .reject { |token| token.include?("instagram.com") }
      .uniq

    hashtags = (
      Array(payload.dig("hashtags")) +
      text.to_s.scan(/#[a-zA-Z0-9_]+/)
    ).map(&:to_s).map(&:downcase).uniq

    {
      faces: (
        Array(payload.dig("faces")) +
        Array(nested["faces"]) +
        Array(payload.dig("faceAnnotations"))
      ).uniq.map { |face| normalize_face(face) },
      ocr_text: text.presence,
      ocr_blocks: ocr_blocks,
      location_tags: location_tags.first(20),
      content_signals: content_labels.first(30),
      object_detections: object_detections.first(60),
      scenes: scenes,
      mentions: mentions.first(30),
      hashtags: hashtags.first(30),
      profile_handles: profile_handles.first(30),
      metadata: {
        source: "local_ai",
        face_count: (
          Array(payload.dig("faces")) +
          Array(nested["faces"]) +
          Array(payload.dig("faceAnnotations"))
        ).length
      }
    }
  end

  def normalize_face(face)
    raw = face.is_a?(Hash) ? face : {}
    bbox = raw.dig("bounding_box") || raw.dig("bbox") || raw.dig("boundingPoly", "vertices")
    age_value = (raw["age"] || raw[:age]).to_f
    gender_value = (raw["gender"] || raw[:gender]).to_s.strip.downcase
    gender_value = nil if gender_value.blank?

    {
      confidence: (raw.dig("confidence") || 0).to_f,
      bounding_box: normalize_bounding_box(bbox),
      landmarks: Array(raw.dig("landmarks") || []).first(12).map do |item|
        {
          type: (item.dig("type") || item.dig("name") || "UNKNOWN").to_s,
          x: item.dig("x") || item.dig("position", "x"),
          y: item.dig("y") || item.dig("position", "y"),
          z: item.dig("z") || item.dig("position", "z")
        }
      end,
      likelihoods: raw.dig("likelihoods") || {},
      age: age_value.positive? ? age_value.round(1) : nil,
      age_range: age_value.positive? ? age_range_for(age_value) : nil,
      gender: gender_value,
      gender_score: (raw["gender_score"] || raw[:gender_score]).to_f
    }
  end

  def age_range_for(age_value)
    age = age_value.to_i
    return "child" if age < 13
    return "teen" if age < 20
    return "young_adult" if age < 30
    return "adult" if age < 45
    return "middle_aged" if age < 60

    "senior"
  end

  def normalize_bounding_box(value)
    if value.is_a?(Hash)
      value
    elsif value.is_a?(Array) && value.length == 4 && value.first.is_a?(Numeric)
      { "x1" => value[0], "y1" => value[1], "x2" => value[2], "y2" => value[3] }
    elsif value.is_a?(Array) && value.length == 4 && value.first.is_a?(Hash)
      xs = value.map { |pt| pt["x"].to_f }
      ys = value.map { |pt| pt["y"].to_f }
      { "x1" => xs.min, "y1" => ys.min, "x2" => xs.max, "y2" => ys.max }
    elsif value.is_a?(Array) && value.length == 4 && value.first.is_a?(Array)
      xs = value.map { |pt| pt[0].to_f }
      ys = value.map { |pt| pt[1].to_f }
      { "x1" => xs.min, "y1" => ys.min, "x2" => xs.max, "y2" => ys.max }
    else
      {}
    end
  end

  def empty_result(reason:, error_message: nil)
    {
      faces: [],
      ocr_text: nil,
      ocr_blocks: [],
      location_tags: [],
      content_signals: [],
      object_detections: [],
      scenes: [],
      mentions: [],
      hashtags: [],
      profile_handles: [],
      metadata: {
        source: "local_ai",
        reason: reason,
        error_message: error_message.to_s.presence
      }.compact
    }
  end

  def normalize_ocr_blocks(payload:, nested:)
    blocks = []

    Array(payload.dig("ocr_blocks")).each do |row|
      next unless row.is_a?(Hash)
      text = row["text"].to_s.strip
      next if text.blank?

      blocks << {
        text: text,
        confidence: row["confidence"].to_f,
        bbox: normalize_bounding_box(row["bbox"]),
        timestamp: row["timestamp"],
        source: row["source"].to_s.presence || "ocr"
      }.compact
    end

    if blocks.empty?
      Array(nested["text"]).each do |row|
        next unless row.is_a?(Hash)
        text = row["text"].to_s.strip
        next if text.blank?

        blocks << {
          text: text,
          confidence: row["confidence"].to_f,
          bbox: normalize_bounding_box(row["bbox"]),
          timestamp: row["timestamp"],
          source: row["source"].to_s.presence || "ocr"
        }.compact
      end
    end

    blocks.first(80)
  end

  def normalize_object_detections(payload:, nested:)
    rows = Array(payload.dig("object_detections"))
    rows = Array(nested["labels"]) if rows.empty?

    rows.filter_map do |row|
      next unless row.is_a?(Hash)
      label = (row["label"] || row["description"]).to_s.strip
      next if label.blank?

      {
        label: label.downcase,
        confidence: (row["confidence"] || row["score"] || row["max_confidence"]).to_f,
        bbox: normalize_bounding_box(row["bbox"]),
        timestamps: Array(row["timestamps"]).map(&:to_f).first(80)
      }.compact
    end.first(80)
  end

end
