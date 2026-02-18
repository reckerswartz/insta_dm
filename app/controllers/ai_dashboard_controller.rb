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
    @service_status = check_ai_services
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

  def check_ai_services
    begin
      uri = URI("#{AI_SERVICE_URL}/health")
      response = Net::HTTP.get_response(uri)
      
      if response.code == '200'
        data = JSON.parse(response.body)
        Ops::IssueTracker.record_ai_service_check!(
          ok: true,
          message: "AI microservice healthy",
          metadata: { services: data["services"] }
        )
        {
          status: 'online',
          services: data['services'] || {},
          last_check: Time.current
        }
      else
        Ops::IssueTracker.record_ai_service_check!(
          ok: false,
          message: "HTTP #{response.code}",
          metadata: { http_status: response.code.to_i, response_body_preview: response.body.to_s.byteslice(0, 250) }
        )
        { status: 'error', message: "HTTP #{response.code}", last_check: Time.current }
      end
    rescue StandardError => e
      Ops::IssueTracker.record_ai_service_check!(
        ok: false,
        message: e.message,
        metadata: { error_class: e.class.name }
      )
      { status: 'offline', message: e.message, last_check: Time.current }
    end
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
      when 'safe_search'
        test_image = create_test_image
        
        uri = URI("#{AI_SERVICE_URL}/analyze/image")
        req = Net::HTTP::Post.new(uri)
        
        boundary = "----WebKitFormBoundary#{SecureRandom.hex(16)}"
        
        post_data = []
        post_data << "--#{boundary}\r\n"
        post_data << "Content-Disposition: form-data; name=\"features\"\r\n\r\n"
        post_data << "safe_search\r\n"
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
            result: data['results']['safe_search'] || {},
            message: "Safe search analysis working"
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
