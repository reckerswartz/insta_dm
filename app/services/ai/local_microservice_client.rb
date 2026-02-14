require "net/http"
require "json"
require "base64"

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
    
    private
    
    def convert_features(google_features)
      # Convert Google Vision feature names to local service names
      feature_map = {
        "LABEL_DETECTION" => "labels",
        "TEXT_DETECTION" => "text",
        "SAFE_SEARCH_DETECTION" => "safe_search",
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
      return {} unless response["success"]
      
      results = response["results"] || {}
      
      # Convert to Google Vision format
      vision_response = {}
      
      # Labels
      if results["labels"]
        vision_response["labelAnnotations"] = results["labels"].map do |label|
          {
            "description" => label["label"],
            "score" => label["confidence"],
            "topicality" => label["confidence"]
          }
        end
      end
      
      # Text
      if results["text"]
        vision_response["textAnnotations"] = results["text"].map.with_index do |text, i|
          {
            "description" => text["text"],
            "confidence" => text["confidence"],
            "boundingPoly" => {
              "vertices" => convert_bbox_to_vertices(text["bbox"])
            }
          }
        end
      end
      
      # Safe Search
      if results["safe_search"]
        vision_response["safeSearchAnnotation"] = convert_safe_search(results["safe_search"])
      end
      
      # Faces
      if results["faces"]
        vision_response["faceAnnotations"] = results["faces"].map do |face|
          {
            "boundingPoly" => {
              "vertices" => convert_bbox_to_vertices(face["bbox"])
            },
            "confidence" => face["confidence"],
            "landmarks" => convert_landmarks(face["landmarks"])
          }
        end
      end
      
      vision_response
    end
    
    def convert_video_response(response)
      return {} unless response["success"]
      
      results = response["results"] || {}
      
      video_response = {
        "annotationResults" => [{}]
      }
      
      # Labels
      if results["labels"]
        video_response["annotationResults"][0]["segmentLabelAnnotations"] = results["labels"].map do |label|
          {
            "entity" => {
              "description" => label["label"],
              "confidence" => label["max_confidence"]
            },
            "segments" => label["timestamps"].map.with_index do |timestamp, i|
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
      if results["scenes"]
        video_response["annotationResults"][0]["shotAnnotations"] = results["scenes"].map do |scene|
          {
            "startTimeOffset" => "#{scene["timestamp"].to_i}s"
          }
        end
      end
      
      video_response
    end
    
    def convert_bbox_to_vertices(bbox)
      return [] unless bbox
      
      if bbox.is_a?(Array) && bbox.length == 4
        # Format: [x1, y1, x2, y2]
        [
          { "x" => bbox[0].to_i, "y" => bbox[1].to_i },
          { "x" => bbox[2].to_i, "y" => bbox[1].to_i },
          { "x" => bbox[2].to_i, "y" => bbox[3].to_i },
          { "x" => bbox[0].to_i, "y" => bbox[3].to_i }
        ]
      elsif bbox.is_a?(Array) && bbox.length == 4 && bbox.first.is_a?(Array)
        # Format: [[x1,y1], [x2,y2], [x3,y3], [x4,y4]]
        bbox.map { |point| { "x" => point[0].to_i, "y" => point[1].to_i } }
      else
        []
      end
    end
    
    def convert_landmarks(landmarks)
      return [] unless landmarks
      
      landmarks.map do |landmark|
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
    
    def convert_safe_search(safe_search)
      # Convert local safe search to Google format
      {
        "adult" => map_safety_level(safe_search["adult"]),
        "violence" => map_safety_level(safe_search["violence"]),
        "racy" => map_safety_level(safe_search["racy"])
      }
    end
    
    def map_safety_level(level)
      case level.to_s
      when "likely"
        "LIKELY"
      when "possible"
        "POSSIBLE"
      when "unlikely"
        "UNLIKELY"
      else
        "UNKNOWN"
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
  end
end
