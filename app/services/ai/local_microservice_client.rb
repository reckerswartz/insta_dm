require "net/http"
require "json"
require "base64"
require "tempfile"

module Ai
  class LocalMicroserviceClient
    BASE_URL = ENV.fetch("LOCAL_AI_SERVICE_URL", "http://localhost:8000").freeze
    
    def initialize(service_url: nil)
      @base_url = service_url || BASE_URL
    end
    
    def test_connection!
      response = get_json("/health")
      raise "Local AI service unavailable" unless response["status"] == "healthy"
      
      {
        ok: true,
        message: "Local AI service is healthy",
        services: response["services"]
      }
    rescue StandardError => e
      { ok: false, message: e.message.to_s }
    end
    
    def analyze_image_bytes!(bytes, features:, usage_category: "image_analysis", usage_context: nil)
      # Convert feature names to match microservice expectations
      service_features = convert_features(features)
      
      # Create temporary file for upload
      temp_file = Tempfile.new(["image_analysis", ".jpg"])
      begin
        temp_file.binmode
        temp_file.write(bytes)
        temp_file.flush
        
        # Upload to microservice
        response = upload_file("/analyze/image", temp_file.path, { features: service_features.join(",") })
        
        # Convert response to match Google Vision format
        convert_vision_response(response)
      ensure
        temp_file.close
        temp_file.unlink
      end
    end
    
    def analyze_image_uri!(url, features:, usage_category: "image_analysis", usage_context: nil)
      # Download image from URL
      uri = URI.parse(url)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = uri.scheme == "https"
      http.open_timeout = 10
      http.read_timeout = 30
      
      response = http.get(uri.request_uri)
      raise "Failed to download image: #{response.code}" unless response.is_a?(Net::HTTPSuccess)
      
      analyze_image_bytes!(response.body, features: features, usage_category: usage_category, usage_context: usage_context)
    end
    
    def analyze_video_bytes!(bytes, features:, usage_context: nil)
      service_features = convert_video_features(features)
      
      temp_file = Tempfile.new(["video_analysis", ".mp4"])
      begin
        temp_file.binmode
        temp_file.write(bytes)
        temp_file.flush
        
        response = upload_file("/analyze/video", temp_file.path, { 
          features: service_features.join(","),
          sample_rate: 2  # Sample every 2 seconds
        })
        
        convert_video_response(response)
      ensure
        temp_file.close
        temp_file.unlink
      end
    end
    
    def fetch_video_operation!(name, usage_context: nil)
      # Local microservice processes synchronously, so return completed status
      {
        "done" => true,
        "response" => { "annotationResults" => [{}] }
      }
    end
    
    def generate_text_json!(model:, prompt:, temperature: 0.8, max_output_tokens: 900, usage_category: "text_generation", usage_context: nil)
      # Use Ollama for text generation
      ollama_client = Ai::OllamaClient.new
      
      response = ollama_client.generate(
        model: model,
        prompt: prompt,
        temperature: temperature,
        max_tokens: max_output_tokens
      )
      
      # Parse JSON response from LLM
      parsed = JSON.parse(response["response"]) rescue nil
      
      {
        raw: response,
        text: response["response"],
        json: parsed,
        usage: {
          input_tokens: response.dig("prompt_eval_count") || 0,
          output_tokens: response.dig("eval_count") || 0,
          total_tokens: (response.dig("prompt_eval_count") || 0) + (response.dig("eval_count") || 0)
        }
      }
    end

    # Returns normalized payload for local story intelligence extraction.
    # Expected keys:
    # - faces: [{ confidence:, bounding_box:, landmarks:, likelihoods: {} }]
    # - ocr_text: "..."
    # - ocr_blocks: [{ text:, confidence:, bbox:, source: }]
    # - content_labels: ["person", "beach", ...]
    # - object_detections: [{ label:, confidence:, bbox: }]
    # - location_tags: []
    # - mentions: ["@user"]
    # - hashtags: ["#tag"]
    def detect_faces_and_ocr!(image_bytes:, usage_context: nil)
      temp_file = Tempfile.new(["story_intel", ".jpg"])
      begin
        temp_file.binmode
        temp_file.write(image_bytes)
        temp_file.flush

        ocr_warning = nil
        begin
          response = upload_file("/analyze/image", temp_file.path, { features: "labels,text,faces" })
          payload, results = unpack_response_payload!(
            response: response,
            operation: "detect_faces_and_ocr",
            expected_keys: %w[labels text faces]
          )
        rescue StandardError => e
          ocr_warning = {
            "feature" => "text",
            "error_class" => e.class.name.to_s,
            "error_message" => e.message.to_s.byteslice(0, 260),
            "fallback" => "labels_faces_only"
          }
          fallback_response = upload_file("/analyze/image", temp_file.path, { features: "labels,faces" })
          payload, results = unpack_response_payload!(
            response: fallback_response,
            operation: "detect_faces_without_text",
            expected_keys: %w[labels faces]
          )
        end

        text_rows = Array(results["text"])
        text_rows = text_rows.map do |row|
          if row.is_a?(Hash)
            source_name = row["source"].to_s.presence || "ocr"
            variant_name = row["variant"].to_s.presence
            {
              "text" => row["text"].to_s,
              "confidence" => row["confidence"],
              "bbox" => normalize_bounding_box(row["bbox"]),
              "source" => [source_name, variant_name].compact.join(":"),
              "variant" => variant_name
            }
          else
            { "text" => row.to_s, "confidence" => nil, "bbox" => {}, "source" => "ocr", "variant" => nil }
          end
        end
        ocr_blocks = text_rows
          .map do |row|
            {
              "text" => row["text"].to_s.strip,
              "confidence" => row["confidence"].to_f,
              "bbox" => row["bbox"].is_a?(Hash) ? row["bbox"] : {},
              "source" => row["source"].to_s.presence || "ocr",
              "variant" => row["variant"].to_s.presence
            }
          end
          .reject { |row| row["text"].blank? }
          .first(80)
        ocr_text = ocr_blocks.map { |row| row["text"] }.uniq.join("\n").presence

        object_detections = Array(results["labels"])
          .map do |row|
            if row.is_a?(Hash)
              {
                "label" => (row["label"] || row["description"]).to_s,
                "confidence" => (row["confidence"] || row["score"]).to_f,
                "bbox" => normalize_bounding_box(row["bbox"])
              }
            else
              { "label" => row.to_s, "confidence" => nil, "bbox" => {} }
            end
          end
          .reject { |row| row["label"].blank? }
          .first(80)

        labels = object_detections
          .map { |row| row["label"] }
          .map(&:to_s)
          .map(&:strip)
          .reject(&:blank?)
          .uniq
          .first(40)

        faces = Array(results["faces"]).map { |face| normalize_face(face) }
        mentions = ocr_text.to_s.scan(/@[a-zA-Z0-9._]+/).map(&:downcase).uniq.first(40)
        hashtags = ocr_text.to_s.scan(/#[a-zA-Z0-9_]+/).map(&:downcase).uniq.first(40)
        profile_handles = ocr_blocks
          .flat_map { |row| row["text"].to_s.scan(/\b([a-zA-Z0-9._]{3,30})\b/) }
          .map { |match| match.is_a?(Array) ? match.first.to_s.downcase : match.to_s.downcase }
          .select { |token| token.include?("_") || token.include?(".") }
          .reject { |token| token.include?("instagram.com") }
          .uniq
          .first(40)

        {
          "faces" => faces,
          "ocr_text" => ocr_text,
          "ocr_blocks" => ocr_blocks,
          "location_tags" => [],
          "content_labels" => labels,
          "object_detections" => object_detections,
          "mentions" => mentions,
          "hashtags" => hashtags,
          "profile_handles" => profile_handles,
          "metadata" => {
            "source" => "local_microservice",
            "usage_context" => usage_context.to_h,
            "warnings" => (
              Array(payload.dig("metadata", "warnings")) +
              Array(ocr_warning)
            ).first(20)
          }
        }
      ensure
        temp_file.close
        temp_file.unlink
      end
    end

    # Returns normalized story intelligence from /analyze/video.
    # - scenes: [{ timestamp:, type:, correlation: }]
    # - content_labels: [..]
    # - object_detections: [{ label:, confidence:, timestamps: [] }]
    # - ocr_text / ocr_blocks
    # - faces: [{ first_seen:, last_seen:, detection_count: }]
    # - mentions / hashtags
    def analyze_video_story_intelligence!(video_bytes:, sample_rate: 2, usage_context: nil)
      temp_file = Tempfile.new(["story_video_intel", ".mp4"])
      begin
        temp_file.binmode
        temp_file.write(video_bytes)
        temp_file.flush

        response = upload_file("/analyze/video", temp_file.path, {
          features: "labels,faces,scenes,text",
          sample_rate: sample_rate.to_i.clamp(1, 5)
        })
        payload, results = unpack_response_payload!(
          response: response,
          operation: "analyze_video_story_intelligence",
          expected_keys: %w[labels faces scenes text]
        )

        scenes = Array(results["scenes"]).map do |row|
          next unless row.is_a?(Hash)
          {
            "timestamp" => row["timestamp"],
            "type" => row["type"].to_s.presence || "scene_change",
            "correlation" => row["correlation"]
          }.compact
        end.compact.first(80)

        object_detections = Array(results["labels"]).map do |row|
          next unless row.is_a?(Hash)
          label = (row["label"] || row["description"]).to_s.strip
          next if label.blank?

          {
            "label" => label,
            "confidence" => (row["max_confidence"] || row["confidence"]).to_f,
            "timestamps" => Array(row["timestamps"]).map(&:to_f).first(80)
          }
        end.compact.first(80)
        content_labels = object_detections.map { |row| row["label"].to_s.downcase }.uniq.first(50)

        ocr_blocks = Array(results["text"]).map do |row|
          next unless row.is_a?(Hash)
          text = row["text"].to_s.strip
          next if text.blank?

          {
            "text" => text,
            "confidence" => row["confidence"].to_f,
            "timestamp" => row["timestamp"],
            "bbox" => normalize_bounding_box(row["bbox"]),
            "source" => row["source"].to_s.presence || "ocr_video"
          }.compact
        end.compact.first(120)
        ocr_text = ocr_blocks.map { |row| row["text"] }.uniq.join("\n").presence

        faces = Array(results["faces"]).map do |row|
          next unless row.is_a?(Hash)
          {
            "first_seen" => row["first_seen"],
            "last_seen" => row["last_seen"],
            "detection_count" => row["detection_count"].to_i
          }.compact
        end.compact.first(60)

        mentions = ocr_text.to_s.scan(/@[a-zA-Z0-9._]+/).map(&:downcase).uniq.first(40)
        hashtags = ocr_text.to_s.scan(/#[a-zA-Z0-9_]+/).map(&:downcase).uniq.first(40)

        {
          "scenes" => scenes,
          "content_labels" => content_labels,
          "object_detections" => object_detections,
          "ocr_text" => ocr_text,
          "ocr_blocks" => ocr_blocks,
          "faces" => faces,
          "mentions" => mentions,
          "hashtags" => hashtags,
          "metadata" => {
            "source" => "local_microservice_video",
            "usage_context" => usage_context.to_h,
            "warnings" => Array(payload.dig("metadata", "warnings")).first(20)
          }
        }
      ensure
        temp_file.close
        temp_file.unlink
      end
    end
    
    private
    
    def convert_features(google_features)
      # Convert Google Vision feature names to local service names
      feature_map = {
        "LABEL_DETECTION" => "labels",
        "TEXT_DETECTION" => "text",
        "FACE_DETECTION" => "faces"
      }
      
      google_features.map { |f| 
        feature_type = f.is_a?(Hash) ? f[:type] || f["type"] : f.to_s
        feature_map[feature_type]
      }.compact.uniq
    end
    
    def convert_video_features(google_features)
      # Convert Google Video Intelligence feature names
      feature_map = {
        "LABEL_DETECTION" => "labels",
        "SHOT_CHANGE_DETECTION" => "scenes",
        "FACE_DETECTION" => "faces",
        "EXPLICIT_CONTENT_DETECTION" => "labels"  # Use labels for explicit content
      }
      
      google_features.map { |f| feature_map[f.to_s] }.compact.uniq
    end
    
    def convert_vision_response(response)
      _payload, results = unpack_response_payload!(
        response: response,
        operation: "analyze_image",
        expected_keys: %w[labels text faces]
      )
      
      # Convert to Google Vision format
      vision_response = {}
      
      # Labels
      if results.key?("labels")
        vision_response["labelAnnotations"] = Array(results["labels"]).map do |label|
          {
            "description" => (label.is_a?(Hash) ? (label["label"] || label["description"]) : label).to_s,
            "score" => (label.is_a?(Hash) ? (label["confidence"] || label["score"]) : nil),
            "topicality" => (label.is_a?(Hash) ? (label["confidence"] || label["score"]) : nil)
          }
        end
      end
      
      # Text
      if results.key?("text")
        vision_response["textAnnotations"] = Array(results["text"]).map.with_index do |text, i|
          entry = text.is_a?(Hash) ? text : { "text" => text.to_s, "confidence" => nil, "bbox" => nil }
          {
            "description" => entry["text"].to_s,
            "confidence" => entry["confidence"],
            "boundingPoly" => {
              "vertices" => convert_bbox_to_vertices(entry["bbox"])
            }
          }
        end
      end
      
      # Faces
      if results.key?("faces")
        vision_response["faceAnnotations"] = Array(results["faces"]).map do |face|
          entry = face.is_a?(Hash) ? face : {}
          {
            "boundingPoly" => {
              "vertices" => convert_bbox_to_vertices(entry["bbox"] || entry["bounding_box"])
            },
            "confidence" => entry["confidence"],
            "landmarks" => convert_landmarks(entry["landmarks"])
          }
        end
      end
      
      vision_response
    end
    
    def convert_video_response(response)
      _payload, results = unpack_response_payload!(
        response: response,
        operation: "analyze_video",
        expected_keys: %w[labels scenes faces]
      )
      
      video_response = {
        "annotationResults" => [{}]
      }
      
      # Labels
      if results.key?("labels")
        video_response["annotationResults"][0]["segmentLabelAnnotations"] = Array(results["labels"]).map do |label|
          row = label.is_a?(Hash) ? label : { "label" => label.to_s, "max_confidence" => 0.0, "timestamps" => [] }
          {
            "entity" => {
              "description" => (row["label"] || row["description"]).to_s,
              "confidence" => (row["max_confidence"] || row["confidence"]).to_f
            },
            "segments" => Array(row["timestamps"]).map.with_index do |timestamp, i|
              {
                "segment" => {
                  "startTimeOffset" => "#{timestamp.to_i}s"
                }
              }
            end
          }
        end
      end
      
      # Shot changes
      if results.key?("scenes")
        video_response["annotationResults"][0]["shotAnnotations"] = Array(results["scenes"]).map do |scene|
          row = scene.is_a?(Hash) ? scene : {}
          {
            "startTimeOffset" => "#{row["timestamp"].to_i}s"
          }
        end
      end
      
      video_response
    end
    
    def convert_bbox_to_vertices(bbox)
      return [] unless bbox
      
      if bbox.is_a?(Array) && bbox.length == 4 && bbox.first.is_a?(Array)
        # Format: [[x1,y1], [x2,y2], [x3,y3], [x4,y4]]
        bbox.map { |point| { "x" => point[0].to_i, "y" => point[1].to_i } }
      elsif bbox.is_a?(Array) && bbox.length == 4
        # Format: [x1, y1, x2, y2]
        [
          { "x" => bbox[0].to_i, "y" => bbox[1].to_i },
          { "x" => bbox[2].to_i, "y" => bbox[1].to_i },
          { "x" => bbox[2].to_i, "y" => bbox[3].to_i },
          { "x" => bbox[0].to_i, "y" => bbox[3].to_i }
        ]
      elsif bbox.is_a?(Hash)
        x1 = (bbox["x1"] || bbox[:x1] || bbox["left"] || bbox[:left]).to_f
        y1 = (bbox["y1"] || bbox[:y1] || bbox["top"] || bbox[:top]).to_f
        x2 = (bbox["x2"] || bbox[:x2] || bbox["right"] || bbox[:right]).to_f
        y2 = (bbox["y2"] || bbox[:y2] || bbox["bottom"] || bbox[:bottom]).to_f
        [
          { "x" => x1.to_i, "y" => y1.to_i },
          { "x" => x2.to_i, "y" => y1.to_i },
          { "x" => x2.to_i, "y" => y2.to_i },
          { "x" => x1.to_i, "y" => y2.to_i }
        ]
      else
        []
      end
    end

    def normalize_face(face)
      raw = face.is_a?(Hash) ? face : {}
      bbox = raw["bounding_box"] || raw["bbox"] || raw[:bounding_box] || raw[:bbox]
      landmarks_raw = raw["landmarks"] || raw[:landmarks]

      {
        "confidence" => (raw["confidence"] || raw[:confidence]).to_f,
        "bounding_box" => normalize_bounding_box(bbox),
        "landmarks" => normalize_landmarks(landmarks_raw),
        "likelihoods" => (raw["likelihoods"] || raw[:likelihoods] || {})
      }
    end

    def normalize_bounding_box(value)
      if value.is_a?(Array) && value.length == 4 && value.first.is_a?(Numeric)
        { "x1" => value[0], "y1" => value[1], "x2" => value[2], "y2" => value[3] }
      elsif value.is_a?(Array) && value.length == 4 && value.first.is_a?(Array)
        xs = value.map { |pt| pt[0].to_f }
        ys = value.map { |pt| pt[1].to_f }
        { "x1" => xs.min, "y1" => ys.min, "x2" => xs.max, "y2" => ys.max }
      elsif value.is_a?(Hash)
        value
      else
        {}
      end
    end

    def normalize_landmarks(value)
      Array(value).first(24).filter_map do |item|
        if item.is_a?(Hash)
          {
            "type" => item["type"].to_s.presence || "UNKNOWN",
            "x" => item["x"] || item.dig("position", "x"),
            "y" => item["y"] || item.dig("position", "y"),
            "z" => item["z"] || item.dig("position", "z")
          }
        elsif item.is_a?(Array)
          { "type" => "UNKNOWN", "x" => item[0], "y" => item[1], "z" => item[2] }
        end
      end
    end
    
    def convert_landmarks(landmarks)
      return [] unless landmarks
      
      landmarks.map do |landmark|
        if landmark.is_a?(Hash)
          x = landmark["x"] || landmark[:x] || landmark.dig("position", "x")
          y = landmark["y"] || landmark[:y] || landmark.dig("position", "y")
          z = landmark["z"] || landmark[:z] || landmark.dig("position", "z")
          {
            "type" => (landmark["type"] || landmark[:type] || "UNKNOWN_LANDMARK").to_s,
            "position" => {
              "x" => x.to_f.to_i,
              "y" => y.to_f.to_i,
              "z" => z.to_f.to_i
            }
          }
        else
          {
            "type" => "UNKNOWN_LANDMARK",  # Would need proper mapping
            "position" => {
              "x" => landmark[0].to_i,
              "y" => landmark[1].to_i,
              "z" => (landmark[2].to_i rescue 0)
            }
          }
        end
      end
    end
    
    def get_json(endpoint)
      uri = URI.parse("#{@base_url}#{endpoint}")
      http = Net::HTTP.new(uri.host, uri.port)
      http.open_timeout = 10
      http.read_timeout = 30
      
      request = Net::HTTP::Get.new(uri.request_uri)
      request["Accept"] = "application/json"
      
      response = http.request(request)
      body = JSON.parse(response.body.to_s.presence || "{}")
      
      return body if response.is_a?(Net::HTTPSuccess)
      
      error = body.dig("error", "message").presence || response.body.to_s.byteslice(0, 500)
      raise "Local AI service error: HTTP #{response.code} #{response.message} - #{error}"
    rescue JSON::ParserError
      raise "Local AI service error: HTTP #{response.code} #{response.message} - #{response.body.to_s.byteslice(0, 500)}"
    end
    
    def upload_file(endpoint, file_path, params = {})
      uri = URI.parse("#{@base_url}#{endpoint}")
      
      # Create multipart form data
      boundary = "----WebKitFormBoundary#{SecureRandom.hex(16)}"
      
      post_body = []
      
      # Add file
      file_content = File.read(file_path)
      filename = File.basename(file_path)
      post_body << "--#{boundary}\r\n"
      post_body << "Content-Disposition: form-data; name=\"file\"; filename=\"#{filename}\"\r\n"
      post_body << "Content-Type: application/octet-stream\r\n\r\n"
      post_body << file_content
      post_body << "\r\n"
      
      # Add parameters
      params.each do |key, value|
        post_body << "--#{boundary}\r\n"
        post_body << "Content-Disposition: form-data; name=\"#{key}\"\r\n\r\n"
        post_body << value.to_s
        post_body << "\r\n"
      end
      
      post_body << "--#{boundary}--\r\n"
      
      http = Net::HTTP.new(uri.host, uri.port)
      http.open_timeout = 30
      http.read_timeout = 120
      
      request = Net::HTTP::Post.new(uri.request_uri)
      request["Content-Type"] = "multipart/form-data; boundary=#{boundary}"
      request["Accept"] = "application/json"
      request.body = post_body.join
      
      response = http.request(request)
      body = JSON.parse(response.body.to_s.presence || "{}")
      
      return body if response.is_a?(Net::HTTPSuccess)
      
      error = body.dig("error", "message").presence || response.body.to_s.byteslice(0, 500)
      raise "Local AI service error: HTTP #{response.code} #{response.message} - #{error}"
    rescue JSON::ParserError
      raise "Local AI service error: HTTP #{response.code} #{response.message} - #{response.body.to_s.byteslice(0, 500)}"
    end

    def unpack_response_payload!(response:, operation:, expected_keys:)
      payload = response.is_a?(Hash) ? deep_stringify_hash(response) : {}
      results = payload["results"].is_a?(Hash) ? payload["results"] : payload
      explicit_failure = payload.key?("success") && !ActiveModel::Type::Boolean.new.cast(payload["success"])
      has_expected_keys = Array(expected_keys).map(&:to_s).any? { |key| results.key?(key) }

      if explicit_failure && !has_expected_keys
        raise "Local AI #{operation} failed: #{response_error_message(payload)}"
      end

      if results.empty? && !has_expected_keys
        if explicit_failure
          raise "Local AI #{operation} failed: #{response_error_message(payload)}"
        end
      end

      [ payload, results ]
    end

    def response_error_message(payload)
      return "unknown error" unless payload.is_a?(Hash)

      error_value = payload["error"]
      nested_error = error_value.is_a?(Hash) ? error_value["message"].to_s.presence : nil

      nested_error ||
        error_value.to_s.presence ||
        payload["message"].to_s.presence ||
        payload["detail"].to_s.presence ||
        "unknown error"
    end

    def deep_stringify_hash(value)
      case value
      when Hash
        value.each_with_object({}) do |(key, child), out|
          out[key.to_s] = deep_stringify_hash(child)
        end
      when Array
        value.map { |child| deep_stringify_hash(child) }
      else
        value
      end
    end
  end
end
