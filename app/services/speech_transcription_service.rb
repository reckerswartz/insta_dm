require "open3"
require "shellwords"
require "tempfile"
require "tmpdir"
require "net/http"
require "json"

class SpeechTranscriptionService
  def initialize(whisper_bin: ENV.fetch("WHISPER_BIN", "whisper"), whisper_model: ENV.fetch("WHISPER_MODEL", "base"), use_microservice: ENV.fetch("USE_LOCAL_AI_MICROSERVICE", "true") == "true")
    @whisper_bin = whisper_bin.to_s
    @whisper_model = whisper_model.to_s
    @use_microservice = use_microservice
    @microservice_url = ENV.fetch("LOCAL_AI_SERVICE_URL", "http://localhost:8000")
  end

  def transcribe(audio_bytes:, story_id:)
    return empty_result("audio_bytes_missing") if audio_bytes.blank?

    # Try microservice first if enabled
    if @use_microservice
      microservice_result = transcribe_with_microservice(audio_bytes, story_id)
      return microservice_result if microservice_result[:transcript].present?
    end

    # Fallback to local Whisper binary
    return empty_result("whisper_missing") unless command_available?(@whisper_bin)

    transcribe_with_binary(audio_bytes, story_id)
  rescue StandardError => e
    empty_result("transcription_error", stderr: e.message)
  end

  private

  def transcribe_with_microservice(audio_bytes, story_id)
    Tempfile.create([ "story_audio_#{story_id}", ".wav" ]) do |audio_file|
      audio_file.binmode
      audio_file.write(audio_bytes)
      audio_file.flush

      uri = URI.parse("#{@microservice_url}/transcribe/audio")
      
      # Create multipart form data
      boundary = "----WebKitFormBoundary#{SecureRandom.hex(16)}"
      
      post_body = []
      post_body << "--#{boundary}\r\n"
      post_body << "Content-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\n"
      post_body << "Content-Type: application/octet-stream\r\n\r\n"
      post_body << audio_bytes
      post_body << "\r\n"
      post_body << "--#{boundary}\r\n"
      post_body << "Content-Disposition: form-data; name=\"model\"\r\n\r\n"
      post_body << @whisper_model
      post_body << "\r\n"
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
      
      if response.is_a?(Net::HTTPSuccess) && body["success"]
        {
          transcript: body["transcript"],
          metadata: {
            source: "local_microservice",
            model: @whisper_model,
            confidence: body.dig("metadata", "confidence")
          }
        }
      else
        empty_result("microservice_error", stderr: body.dig("error"))
      end
    end
  rescue StandardError => e
    empty_result("microservice_error", stderr: e.message)
  end

  def transcribe_with_binary(audio_bytes, story_id)
    Tempfile.create([ "story_audio_#{story_id}", ".wav" ]) do |audio_file|
      audio_file.binmode
      audio_file.write(audio_bytes)
      audio_file.flush

      Dir.mktmpdir("story_whisper_#{story_id}_") do |output_dir|
        cmd = [
          @whisper_bin,
          audio_file.path,
          "--model", @whisper_model,
          "--output_format", "txt",
          "--output_dir", output_dir,
          "--task", "transcribe"
        ]
        _stdout, stderr, status = Open3.capture3(*cmd)
        return empty_result("whisper_failed", stderr: stderr.to_s) unless status.success?

        txt_path = Dir[File.join(output_dir, "*.txt")].first
        return empty_result("transcript_missing") if txt_path.blank?

        text = File.read(txt_path).to_s.strip
        return empty_result("transcript_empty") if text.blank?

        {
          transcript: text,
          metadata: {
            source: "local_whisper_binary",
            model: @whisper_model
          }
        }
      end
    end
  end

  def command_available?(command)
    system("command -v #{Shellwords.escape(command)} >/dev/null 2>&1")
  end

  def empty_result(reason, stderr: nil)
    {
      transcript: nil,
      metadata: {
        source: "local_whisper",
        reason: reason,
        stderr: stderr.to_s.presence
      }.compact
    }
  end
end
