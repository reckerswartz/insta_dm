class AiDashboardController < ApplicationController
  before_action :require_current_account!
  skip_forgery_protection only: [:test_service, :test_all_services]

  require 'net/http'
  require 'uri'
  require 'json'
  require 'base64'
  require 'securerandom'

  AI_SERVICE_URL = "http://localhost:8000"

  def index
    @service_status = check_ai_services(force: refresh_requested?)
    @test_results = {}
  end

  def test_service
    service_name = params[:service_name]
    test_type = params[:test_type]

    case service_name
    when 'vision'
      @test_results = test_vision_service(test_type)
    when 'face'
      @test_results = test_face_service(test_type)
    when 'ocr'
      @test_results = test_ocr_service(test_type)
    when 'whisper'
      @test_results = test_whisper_service(test_type)
    when 'video'
      @test_results = test_video_service(test_type)
    else
      @test_results = { error: "Unknown service: #{service_name}" }
    end

    respond_to do |format|
      format.json { render json: @test_results }
      format.html { 
        flash[:notice] = "Test completed for #{service_name}"
        redirect_to ai_dashboard_path 
      }
    end
  end

  def test_all_services
    @test_results = {}
    
    @test_results[:vision] = test_vision_service('labels')
    @test_results[:face] = test_face_service('detection')
    @test_results[:ocr] = test_ocr_service('text_extraction')
    @test_results[:whisper] = test_whisper_service('transcription')
    @test_results[:video] = test_video_service('analysis')

    respond_to do |format|
      format.json { render json: @test_results }
      format.html { 
        flash[:notice] = "All services tested"
        redirect_to ai_dashboard_path 
      }
    end
  end

  private

  def check_ai_services(force: false)
    health = Ops::LocalAiHealth.check(force: force)
    checked_at = Time.current

    if ActiveModel::Type::Boolean.new.cast(health[:ok])
      service_map = health.dig(:details, :microservice, :services) || {}
      service_map = service_map.merge(
        "ollama" => Array(health.dig(:details, :ollama, :models)).any?
      )

      Ops::IssueTracker.record_ai_service_check!(
        ok: true,
        message: "Local AI stack healthy",
        metadata: health
      )

      {
        status: "online",
        services: service_map,
        last_check: checked_at
      }
    else
      message = health[:error].presence || "Local AI stack unavailable"

      Ops::IssueTracker.record_ai_service_check!(
        ok: false,
        message: message,
        metadata: health
      )

      {
        status: "offline",
        message: message,
        last_check: checked_at
      }
    end
  end

  def refresh_requested?
    ActiveModel::Type::Boolean.new.cast(params[:refresh])
  end

  def test_vision_service(test_type)
    begin
      case test_type
      when 'labels'
        test_image = create_test_image
        
        uri = URI("#{AI_SERVICE_URL}/analyze/image")
        req = Net::HTTP::Post.new(uri)
        
        # Create multipart form data
        boundary = "----WebKitFormBoundary#{SecureRandom.hex(16)}"
        
        post_data = []
        post_data << "--#{boundary}\r\n"
        post_data << "Content-Disposition: form-data; name=\"features\"\r\n\r\n"
        post_data << "labels\r\n"
        post_data << "--#{boundary}\r\n"
        post_data << "Content-Disposition: form-data; name=\"file\"; filename=\"test.png\"\r\n"
        post_data << "Content-Type: image/png\r\n\r\n"
        post_data << test_image
        post_data << "\r\n--#{boundary}--\r\n"
        
        req.body = post_data.join
        req['Content-Type'] = "multipart/form-data; boundary=#{boundary}"
        
        response = Net::HTTP.start(uri.hostname, uri.port) do |http|
          http.request(req)
        end
        
        if response.code == '200'
          data = JSON.parse(response.body)
          {
            success: true,
            result: data['results']['labels'] || [],
            message: "Label detection working - found #{(data['results']['labels'] || []).length} objects"
          }
        else
          { success: false, error: "HTTP #{response.code}: #{response.body}" }
        end
      else
        { success: false, error: "Unknown test type: #{test_type}" }
      end
    rescue StandardError => e
      { success: false, error: e.message }
    end
  end

  def test_face_service(test_type)
    begin
      case test_type
      when 'detection'
        test_image = create_test_image
        
        uri = URI("#{AI_SERVICE_URL}/analyze/image")
        req = Net::HTTP::Post.new(uri)
        
        boundary = "----WebKitFormBoundary#{SecureRandom.hex(16)}"
        
        post_data = []
        post_data << "--#{boundary}\r\n"
        post_data << "Content-Disposition: form-data; name=\"features\"\r\n\r\n"
        post_data << "faces\r\n"
        post_data << "--#{boundary}\r\n"
        post_data << "Content-Disposition: form-data; name=\"file\"; filename=\"test.png\"\r\n"
        post_data << "Content-Type: image/png\r\n\r\n"
        post_data << test_image
        post_data << "\r\n--#{boundary}--\r\n"
        
        req.body = post_data.join
        req['Content-Type'] = "multipart/form-data; boundary=#{boundary}"
        
        response = Net::HTTP.start(uri.hostname, uri.port) do |http|
          http.request(req)
        end
        
        if response.code == '200'
          data = JSON.parse(response.body)
          face_count = (data['results']['faces'] || []).length
          {
            success: true,
            result: data['results']['faces'] || [],
            message: "Face detection working - found #{face_count} face(s)"
          }
        else
          { success: false, error: "HTTP #{response.code}: #{response.body}" }
        end
      when 'embedding'
        test_image = create_test_image
        
        uri = URI("#{AI_SERVICE_URL}/face/embedding")
        req = Net::HTTP::Post.new(uri)
        
        boundary = "----WebKitFormBoundary#{SecureRandom.hex(16)}"
        
        post_data = []
        post_data << "--#{boundary}\r\n"
        post_data << "Content-Disposition: form-data; name=\"file\"; filename=\"test.png\"\r\n"
        post_data << "Content-Type: image/png\r\n\r\n"
        post_data << test_image
        post_data << "\r\n--#{boundary}--\r\n"
        
        req.body = post_data.join
        req['Content-Type'] = "multipart/form-data; boundary=#{boundary}"
        
        response = Net::HTTP.start(uri.hostname, uri.port) do |http|
          http.request(req)
        end
        
        if response.code == '200'
          data = JSON.parse(response.body)
          embedding_size = data['metadata']['embedding_size'] || 0
          {
            success: true,
            result: data['embedding'] ? "Embedding generated (size: #{embedding_size})" : nil,
            message: "Face embedding working - generated #{embedding_size}-dimensional vector"
          }
        else
          { success: false, error: "HTTP #{response.code}: #{response.body}" }
        end
      when 'comparison'
        test_image = create_test_image
        
        uri = URI("#{AI_SERVICE_URL}/face/compare")
        req = Net::HTTP::Post.new(uri)
        
        boundary = "----WebKitFormBoundary#{SecureRandom.hex(16)}"
        
        post_data = []
        post_data << "--#{boundary}\r\n"
        post_data << "Content-Disposition: form-data; name=\"file1\"; filename=\"test1.png\"\r\n"
        post_data << "Content-Type: image/png\r\n\r\n"
        post_data << test_image
        post_data << "\r\n--#{boundary}\r\n"
        post_data << "Content-Disposition: form-data; name=\"file2\"; filename=\"test2.png\"\r\n"
        post_data << "Content-Type: image/png\r\n\r\n"
        post_data << test_image
        post_data << "\r\n--#{boundary}--\r\n"
        
        req.body = post_data.join
        req['Content-Type'] = "multipart/form-data; boundary=#{boundary}"
        
        response = Net::HTTP.start(uri.hostname, uri.port) do |http|
          http.request(req)
        end
        
        if response.code == '200'
          data = JSON.parse(response.body)
          similarity = data['similarity'] || 0
          {
            success: true,
            result: data,
            message: "Face comparison working - similarity score: #{similarity.round(3)}"
          }
        else
          { success: false, error: "HTTP #{response.code}: #{response.body}" }
        end
      else
        { success: false, error: "Unknown test type: #{test_type}" }
      end
    rescue StandardError => e
      { success: false, error: e.message }
    end
  end

  def test_ocr_service(test_type)
    begin
      case test_type
      when 'text_extraction'
        test_image = create_test_image_with_text
        
        uri = URI("#{AI_SERVICE_URL}/analyze/image")
        req = Net::HTTP::Post.new(uri)
        
        boundary = "----WebKitFormBoundary#{SecureRandom.hex(16)}"
        
        post_data = []
        post_data << "--#{boundary}\r\n"
        post_data << "Content-Disposition: form-data; name=\"features\"\r\n\r\n"
        post_data << "text\r\n"
        post_data << "--#{boundary}\r\n"
        post_data << "Content-Disposition: form-data; name=\"file\"; filename=\"test.png\"\r\n"
        post_data << "Content-Type: image/png\r\n\r\n"
        post_data << test_image
        post_data << "\r\n--#{boundary}--\r\n"
        
        req.body = post_data.join
        req['Content-Type'] = "multipart/form-data; boundary=#{boundary}"
        
        response = Net::HTTP.start(uri.hostname, uri.port) do |http|
          http.request(req)
        end
        
        if response.code == '200'
          data = JSON.parse(response.body)
          text_count = (data['results']['text'] || []).length
          extracted_text = (data['results']['text'] || []).map { |t| t['text'] }.join(', ')
          {
            success: true,
            result: data['results']['text'] || [],
            message: "OCR text extraction working - found #{text_count} text region(s): #{extracted_text.length > 50 ? extracted_text[0..47] + '...' : extracted_text}"
          }
        else
          { success: false, error: "HTTP #{response.code}: #{response.body}" }
        end
      else
        { success: false, error: "Unknown test type: #{test_type}" }
      end
    rescue StandardError => e
      { success: false, error: e.message }
    end
  end

  def test_whisper_service(test_type)
    begin
      case test_type
      when 'transcription'
        # For now, just test if the endpoint responds
        # In a real implementation, you'd create a test audio file
        uri = URI("#{AI_SERVICE_URL}/transcribe/audio")
        req = Net::HTTP::Post.new(uri)
        
        response = Net::HTTP.start(uri.hostname, uri.port) do |http|
          http.request(req)
        end
        
        # We expect this to fail without a file, but it shows the service is running
        if response.code == '422' || response.code == '400'
          {
            success: true,
            result: "Endpoint accessible",
            message: "Whisper service responding"
          }
        else
          { success: false, error: "Unexpected response: #{response.code}" }
        end
      else
        { success: false, error: "Unknown test type: #{test_type}" }
      end
    rescue StandardError => e
      { success: false, error: e.message }
    end
  end

  def test_video_service(test_type)
    begin
      case test_type
      when 'analysis'
        # For now, just test if the endpoint responds
        uri = URI("#{AI_SERVICE_URL}/analyze/video")
        req = Net::HTTP::Post.new(uri)
        
        response = Net::HTTP.start(uri.hostname, uri.port) do |http|
          http.request(req)
        end
        
        # We expect this to fail without a file, but it shows the service is running
        if response.code == '422' || response.code == '400'
          {
            success: true,
            result: "Endpoint accessible",
            message: "Video service responding"
          }
        else
          { success: false, error: "Unexpected response: #{response.code}" }
        end
      else
        { success: false, error: "Unknown test type: #{test_type}" }
      end
    rescue StandardError => e
      { success: false, error: e.message }
    end
  end

  def create_test_image
    # Create a simple 1x1 pixel PNG image for testing
    require 'base64'
    
    # Base64 encoded 1x1 transparent PNG
    png_data = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=="
    Base64.decode64(png_data)
  end

  def create_test_image_with_text
    # Create a simple test image that might contain some text patterns
    # For now, use the same test image - in a real implementation you'd create
    # an image with actual text for OCR testing
    create_test_image
  end
end
