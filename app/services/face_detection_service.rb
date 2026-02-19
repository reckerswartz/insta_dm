class FaceDetectionService
  DEFAULT_MIN_FACE_CONFIDENCE = ENV.fetch("FACE_DETECTION_MIN_CONFIDENCE", "0.25").to_f
  FACE_DUPLICATE_IOU_THRESHOLD = ENV.fetch("FACE_DETECTION_DUPLICATE_IOU_THRESHOLD", "0.85").to_f

  def initialize(client: nil, min_face_confidence: nil)
    @client = client || build_local_client
    @min_face_confidence = begin
      value = min_face_confidence.nil? ? DEFAULT_MIN_FACE_CONFIDENCE : min_face_confidence.to_f
      value.negative? ? 0.0 : value
    rescue StandardError
      DEFAULT_MIN_FACE_CONFIDENCE
    end
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
    payload = deep_stringify(response.is_a?(Hash) ? response : {})
    nested = payload["results"].is_a?(Hash) ? payload["results"] : {}

    text_from_payload = payload.dig("ocr_text").to_s
    text_from_payload_blocks = Array(payload["text"]).map { |row| row.is_a?(Hash) ? row["text"].to_s : row.to_s }.map(&:strip).reject(&:blank?).uniq.join("\n")
    text_from_nested = Array(nested["text"]).map { |row| row.is_a?(Hash) ? row["text"].to_s : row.to_s }.map(&:strip).reject(&:blank?).uniq.join("\n")
    text = [text_from_payload, text_from_payload_blocks, text_from_nested].map(&:strip).reject(&:blank?).join("\n").presence
    ocr_blocks = normalize_ocr_blocks(payload: payload, nested: nested)

    location_tags = (Array(payload.dig("location_tags")) + Array(nested.dig("location_tags"))).map(&:to_s).map(&:strip).reject(&:blank?).uniq
    content_labels = (
      Array(payload.dig("content_labels")) +
      Array(nested.dig("content_labels")) +
      Array(payload["labels"]).map { |row| row.is_a?(Hash) ? (row["label"] || row["description"]) : row } +
      Array(nested["labels"]).map { |row| row.is_a?(Hash) ? (row["label"] || row["description"]) : row }
    ).map { |value| value.to_s.downcase.strip }.reject(&:blank?).uniq
    object_detections = normalize_object_detections(payload: payload, nested: nested)
    scenes = (Array(payload.dig("scenes")) + Array(nested["scenes"])).map do |row|
      next unless row.is_a?(Hash)
      {
        timestamp: row["timestamp"] || row[:timestamp],
        type: (row["type"] || row[:type]).to_s.presence || "scene_change",
        correlation: row["correlation"] || row[:correlation]
      }.compact
    end.compact.first(80)

    mentions = (
      Array(payload.dig("mentions")) +
      Array(nested.dig("mentions")) +
      text.to_s.scan(/@[a-zA-Z0-9._]+/)
    ).map(&:to_s).map(&:downcase).uniq
    profile_handles = (
      Array(payload.dig("profile_handles")) +
      Array(nested.dig("profile_handles")) +
      text.to_s.scan(/\b[a-zA-Z0-9._]{3,30}\b/)
    ).map(&:to_s)
      .map(&:downcase)
      .select { |token| token.include?("_") || token.include?(".") }
      .reject { |token| token.include?("instagram.com") }
      .uniq

    hashtags = (
      Array(payload.dig("hashtags")) +
      Array(nested.dig("hashtags")) +
      text.to_s.scan(/#[a-zA-Z0-9_]+/)
    ).map(&:to_s).map(&:downcase).uniq

    raw_faces = (
      Array(payload.dig("faces")) +
      Array(nested["faces"]) +
      Array(payload.dig("faceAnnotations")) +
      Array(nested.dig("faceAnnotations"))
    )
    normalized_faces = raw_faces.map { |face| normalize_face(face) }
    filtered_faces = normalized_faces.select { |face| keep_face?(face) }
    faces = deduplicate_faces(filtered_faces)
    warnings = Array(payload.dig("metadata", "warnings")) + Array(nested.dig("metadata", "warnings"))
    metadata_reason = payload.dig("metadata", "reason").to_s.presence || nested.dig("metadata", "reason").to_s.presence

    {
      faces: faces,
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
        source: payload.dig("metadata", "source").to_s.presence || nested.dig("metadata", "source").to_s.presence || "local_ai",
        face_count: faces.length,
        detected_face_count: raw_faces.length,
        filtered_face_count: filtered_faces.length,
        dropped_face_count: [ raw_faces.length - faces.length, 0 ].max,
        min_face_confidence: @min_face_confidence,
        reason: metadata_reason,
        warnings: warnings.first(20)
      }.compact
    }
  end

  def normalize_face(face)
    raw = deep_stringify(face.is_a?(Hash) ? face : {})
    bbox = raw.dig("bounding_box") || raw.dig("bbox") || raw.dig("boundingPoly", "vertices")
    age_value = raw["age"].to_f
    gender_value = raw["gender"].to_s.strip.downcase
    gender_value = nil if gender_value.blank?

    {
      confidence: (raw["confidence"] || raw["score"] || 0).to_f,
      bounding_box: normalize_bounding_box(bbox),
      landmarks: Array(raw.dig("landmarks") || []).first(12).filter_map do |item|
        row = deep_stringify(item)
        next unless row.is_a?(Hash)
        {
          type: (row.dig("type") || row.dig("name") || "UNKNOWN").to_s,
          x: row.dig("x") || row.dig("position", "x"),
          y: row.dig("y") || row.dig("position", "y"),
          z: row.dig("z") || row.dig("position", "z")
        }
      end,
      likelihoods: raw.dig("likelihoods") || {},
      age: age_value.positive? ? age_value.round(1) : nil,
      age_range: age_value.positive? ? age_range_for(age_value) : nil,
      gender: gender_value,
      gender_score: raw["gender_score"].to_f
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
      row = deep_stringify(value)
      if row.key?("x1") && row.key?("y1") && row.key?("x2") && row.key?("y2")
        { "x1" => row["x1"].to_f, "y1" => row["y1"].to_f, "x2" => row["x2"].to_f, "y2" => row["y2"].to_f }
      elsif row.key?("x") && row.key?("y") && row.key?("width") && row.key?("height")
        x = row["x"].to_f
        y = row["y"].to_f
        width = row["width"].to_f
        height = row["height"].to_f
        { "x1" => x, "y1" => y, "x2" => x + width, "y2" => y + height }
      else
        {}
      end
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
      (Array(payload["text"]) + Array(nested["text"])).each do |row|
        if row.is_a?(Hash)
          text = row["text"].to_s.strip
          next if text.blank?

          blocks << {
            text: text,
            confidence: row["confidence"].to_f,
            bbox: normalize_bounding_box(row["bbox"]),
            timestamp: row["timestamp"],
            source: row["source"].to_s.presence || "ocr"
          }.compact
        else
          text = row.to_s.strip
          next if text.blank?

          blocks << {
            text: text,
            confidence: 0.0,
            bbox: {},
            source: "ocr"
          }
        end
      end
    end

    blocks.first(80)
  end

  def normalize_object_detections(payload:, nested:)
    rows = Array(payload.dig("object_detections"))
    rows = Array(payload["labels"]) if rows.empty?
    rows = Array(nested["labels"]) if rows.empty?

    rows.filter_map do |row|
      entry = deep_stringify(row)
      label = if entry.is_a?(Hash)
        (entry["label"] || entry["description"]).to_s.strip
      else
        entry.to_s.strip
      end
      next if label.blank?

      {
        label: label.downcase,
        confidence: entry.is_a?(Hash) ? (entry["confidence"] || entry["score"] || entry["max_confidence"]).to_f : 0.0,
        bbox: entry.is_a?(Hash) ? normalize_bounding_box(entry["bbox"]) : {},
        timestamps: entry.is_a?(Hash) ? Array(entry["timestamps"]).map(&:to_f).first(80) : []
      }.compact
    end.first(80)
  end

  def keep_face?(face)
    return false unless face.is_a?(Hash)
    return false unless valid_bounding_box?(face[:bounding_box])

    confidence = face[:confidence].to_f
    return false if confidence <= 0.0

    confidence >= @min_face_confidence
  end

  def valid_bounding_box?(bbox)
    row = bbox.is_a?(Hash) ? bbox : {}
    return false if row.empty?

    x1 = row["x1"].to_f
    y1 = row["y1"].to_f
    x2 = row["x2"].to_f
    y2 = row["y2"].to_f
    return false unless x2 > x1 && y2 > y1

    width = x2 - x1
    height = y2 - y1
    width.positive? && height.positive?
  end

  def deduplicate_faces(faces)
    accepted = []

    Array(faces)
      .sort_by { |face| [ -face[:confidence].to_f, -bounding_box_area(face[:bounding_box]) ] }
      .each do |face|
        duplicate = accepted.any? do |existing|
          bounding_box_iou(existing[:bounding_box], face[:bounding_box]) >= FACE_DUPLICATE_IOU_THRESHOLD
        end
        next if duplicate

        accepted << face
      end

    accepted
  end

  def bounding_box_area(bbox)
    row = bbox.is_a?(Hash) ? bbox : {}
    return 0.0 if row.empty?

    width = row["x2"].to_f - row["x1"].to_f
    height = row["y2"].to_f - row["y1"].to_f
    return 0.0 unless width.positive? && height.positive?

    width * height
  end

  def bounding_box_iou(left_bbox, right_bbox)
    left = left_bbox.is_a?(Hash) ? left_bbox : {}
    right = right_bbox.is_a?(Hash) ? right_bbox : {}
    return 0.0 if left.empty? || right.empty?

    x_left = [ left["x1"].to_f, right["x1"].to_f ].max
    y_top = [ left["y1"].to_f, right["y1"].to_f ].max
    x_right = [ left["x2"].to_f, right["x2"].to_f ].min
    y_bottom = [ left["y2"].to_f, right["y2"].to_f ].min

    inter_width = x_right - x_left
    inter_height = y_bottom - y_top
    return 0.0 unless inter_width.positive? && inter_height.positive?

    intersection = inter_width * inter_height
    union = bounding_box_area(left) + bounding_box_area(right) - intersection
    return 0.0 unless union.positive?

    intersection / union
  end

  def deep_stringify(value)
    case value
    when Hash
      value.each_with_object({}) do |(key, child), out|
        out[key.to_s] = deep_stringify(child)
      end
    when Array
      value.map { |child| deep_stringify(child) }
    else
      value
    end
  end
end
