# frozen_string_literal: true

module AiDashboard
  # Service for testing AI microservices
  # Extracted from AiDashboardController to follow Single Responsibility Principle
  class ServiceTester
    require 'net/http'
    require 'uri'
    require 'json'
    require 'base64'
    require 'securerandom'

    AI_SERVICE_URL = "http://localhost:8000"

    def initialize(service_name:, test_type:)
      @service_name = service_name.to_s
      @test_type = test_type.to_s
    end

    def call
      case @service_name
      when 'vision'
        test_vision_service
      when 'face'
        test_face_service
      when 'ocr'
        test_ocr_service
      when 'whisper'
        test_whisper_service
      when 'video'
        test_video_service
      else
        { error: "Unknown service: #{@service_name}" }
      end
    rescue StandardError => e
      { error: e.message }
    end

    def self.test_all_services
      tester = new(service_name: nil, test_type: nil)
      {
        vision: tester.send(:test_vision_service, 'labels'),
        face: tester.send(:test_face_service, 'detection'),
        ocr: tester.send(:test_ocr_service, 'text_extraction'),
        whisper: tester.send(:test_whisper_service, 'transcription'),
        video: tester.send(:test_video_service, 'analysis')
      }
    rescue StandardError => e
      { error: "Service testing failed: #{e.message}" }
    end

    private

    def test_vision_service(test_type = @test_type)
      case test_type
      when 'labels'
        test_image_analysis(features: 'labels', description: 'Label detection')
      else
        { error: "Unknown test type: #{test_type}" }
      end
    end

    def test_face_service(test_type = @test_type)
      case test_type
      when 'detection'
        test_image_analysis(features: 'faces', description: 'Face detection')
      when 'embedding'
        test_face_embedding
      else
        { error: "Unknown test type: #{test_type}" }
      end
    end

    def test_ocr_service(test_type = @test_type)
      case test_type
      when 'text_extraction'
        test_image_analysis(features: 'text', description: 'OCR text extraction', test_image: :with_text)
      else
        { error: "Unknown test type: #{test_type}" }
      end
    end

    def test_whisper_service(test_type = @test_type)
      case test_type
      when 'transcription'
        test_endpoint_accessibility("#{AI_SERVICE_URL}/transcribe/audio", 'Whisper service')
      else
        { error: "Unknown test type: #{test_type}" }
      end
    end

    def test_video_service(test_type = @test_type)
      case test_type
      when 'analysis'
        test_endpoint_accessibility("#{AI_SERVICE_URL}/analyze/video", 'Video service')
      else
        { error: "Unknown test type: #{test_type}" }
      end
    end

    def test_image_analysis(features:, description:, test_image: :basic)
      test_image_bytes = create_test_image(test_image)
      
      uri = URI("#{AI_SERVICE_URL}/analyze/image")
      req = Net::HTTP::Post.new(uri)
      
      boundary = "----WebKitFormBoundary#{SecureRandom.hex(16)}"
      post_data = build_multipart_data(boundary, features, test_image_bytes)
      
      req.body = post_data.join
      req['Content-Type'] = "multipart/form-data; boundary=#{boundary}"
      
      response = Net::HTTP.start(uri.hostname, uri.port) { |http| http.request(req) }
      
      if response.code == '200'
        data = JSON.parse(response.body)
        format_analysis_success_response(data, features, description)
      else
        { error: "HTTP #{response.code}: #{response.body}" }
      end
    end

    def test_face_embedding
      test_image_bytes = create_test_image
      
      uri = URI("#{AI_SERVICE_URL}/face/embedding")
      req = Net::HTTP::Post.new(uri)
      
      boundary = "----WebKitFormBoundary#{SecureRandom.hex(16)}"
      post_data = build_multipart_data(boundary, nil, test_image_bytes, include_features: false)
      
      req.body = post_data.join
      req['Content-Type'] = "multipart/form-data; boundary=#{boundary}"
      
      response = Net::HTTP.start(uri.hostname, uri.port) { |http| http.request(req) }
      
      if response.code == '200'
        data = JSON.parse(response.body)
        embedding_size = data['metadata']['embedding_size'] || 0
        {
          success: true,
          result: data['embedding'] ? "Embedding generated (size: #{embedding_size})" : nil,
          message: "Face embedding working - generated #{embedding_size}-dimensional vector"
        }
      else
        { error: "HTTP #{response.code}: #{response.body}" }
      end
    end

    def test_endpoint_accessibility(url, service_name)
      uri = URI(url)
      req = Net::HTTP::Post.new(uri)
      
      response = Net::HTTP.start(uri.hostname, uri.port) { |http| http.request(req) }
      
      # We expect this to fail without a file, but it shows the service is running
      if response.code == '422' || response.code == '400'
        {
          success: true,
          result: "Endpoint accessible",
          message: "#{service_name} responding"
        }
      else
        { error: "Unexpected response: #{response.code}" }
      end
    end

    def build_multipart_data(boundary, features, image_bytes, include_features: true)
      post_data = []
      
      if include_features && features
        post_data << "--#{boundary}\r\n"
        post_data << "Content-Disposition: form-data; name=\"features\"\r\n\r\n"
        post_data << "#{features}\r\n"
      end
      
      post_data << "--#{boundary}\r\n"
      post_data << "Content-Disposition: form-data; name=\"file\"; filename=\"test.png\"\r\n"
      post_data << "Content-Type: image/png\r\n\r\n"
      post_data << image_bytes
      post_data << "\r\n--#{boundary}--\r\n"
      
      post_data
    end

    def format_analysis_success_response(data, features, description)
      case features
      when 'labels'
        labels = data['results']['labels'] || []
        {
          success: true,
          result: labels,
          message: "#{description} working - found #{labels.length} objects"
        }
      when 'faces'
        faces = data['results']['faces'] || []
        {
          success: true,
          result: faces,
          message: "#{description} working - found #{faces.length} face(s)"
        }
      when 'text'
        text_results = data['results']['text'] || []
        extracted_text = text_results.map { |t| t['text'] }.join(', ')
        {
          success: true,
          result: text_results,
          message: "#{description} working - found #{text_results.length} text region(s): #{format_extracted_text(extracted_text)}"
        }
      else
        {
          success: true,
          result: data['results'],
          message: "#{description} completed successfully"
        }
      end
    end

    def format_extracted_text(text)
      return text if text.length <= 50
      text[0..47] + '...'
    end

    def create_test_image(type = :basic)
      case type
      when :with_text
        # For OCR testing, you could create an image with actual text
        # For now, using the same basic image
        create_basic_test_image
      else
        create_basic_test_image
      end
    end

    def create_basic_test_image
      # Base64 encoded 1x1 transparent PNG
      png_data = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=="
      Base64.decode64(png_data)
    end
  end
end
