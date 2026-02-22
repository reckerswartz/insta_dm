require "open3"
require "shellwords"
require "tempfile"
require "tmpdir"
require "net/http"
require "json"
require "securerandom"

class SpeechTranscriptionService
  MICROSERVICE_OPEN_TIMEOUT_SECONDS = ENV.fetch("LOCAL_AI_TRANSCRIBE_OPEN_TIMEOUT_SECONDS", "3").to_i.clamp(1, 30)
  MICROSERVICE_READ_TIMEOUT_SECONDS = ENV.fetch("LOCAL_AI_TRANSCRIBE_READ_TIMEOUT_SECONDS", "25").to_i.clamp(5, 180)
  MICROSERVICE_FAILURE_COOLDOWN_SECONDS = ENV.fetch("LOCAL_AI_TRANSCRIBE_FAILURE_COOLDOWN_SECONDS", "120").to_i.clamp(10, 900)

  @microservice_backoff_until = Time.at(0)
  @microservice_backoff_reason = nil
  @microservice_backoff_mutex = Mutex.new

  class << self
    def microservice_backoff_active?
      snapshot = microservice_backoff_snapshot
      ActiveModel::Type::Boolean.new.cast(snapshot[:active])
    end

    def microservice_backoff_snapshot
      with_microservice_backoff_lock do
        now = Time.current
        until_at = @microservice_backoff_until || Time.at(0)
        remaining = until_at > now ? (until_at - now).to_i : 0
        {
          active: remaining.positive?,
          remaining_seconds: remaining,
          reason: @microservice_backoff_reason.to_s.presence
        }
      end
    end

    def mark_microservice_backoff!(reason:)
      with_microservice_backoff_lock do
        @microservice_backoff_until = Time.current + MICROSERVICE_FAILURE_COOLDOWN_SECONDS.seconds
        @microservice_backoff_reason = reason.to_s.byteslice(0, 220)
      end
    rescue StandardError
      nil
    end

    def clear_microservice_backoff!
      with_microservice_backoff_lock do
        @microservice_backoff_until = Time.at(0)
        @microservice_backoff_reason = nil
      end
    rescue StandardError
      nil
    end

    private

    def with_microservice_backoff_lock
      @microservice_backoff_mutex ||= Mutex.new
      @microservice_backoff_mutex.synchronize { yield }
    end
  end

  def initialize(whisper_bin: ENV.fetch("WHISPER_BIN", "whisper"), whisper_model: ENV.fetch("WHISPER_MODEL", "base"), use_microservice: ENV.fetch("USE_LOCAL_AI_MICROSERVICE", "false") == "true")
    @whisper_bin = whisper_bin.to_s
    @whisper_model = whisper_model.to_s
    @use_microservice = use_microservice
    @microservice_url = ENV.fetch("LOCAL_AI_SERVICE_URL", "http://localhost:8000")
  end

  def transcribe(audio_bytes:, story_id:)
    return empty_result("audio_bytes_missing") if audio_bytes.blank?
    fallback_reasons = []

    # Try microservice first if enabled and not in temporary backoff.
    if @use_microservice
      if self.class.microservice_backoff_active?
        snapshot = self.class.microservice_backoff_snapshot
        fallback_reasons << "microservice_backoff_active:#{snapshot[:remaining_seconds]}s"
      else
        microservice_result = transcribe_with_microservice(audio_bytes, story_id)
        return microservice_result if microservice_result[:transcript].present?

        microservice_reason = microservice_result.dig(:metadata, :reason).to_s.presence
        fallback_reasons << (microservice_reason || "microservice_unavailable")
      end
    end

    # Fallback to local Whisper binary
    return empty_result("whisper_missing", fallback_reasons: fallback_reasons) unless command_available?(@whisper_bin)

    result = transcribe_with_binary(audio_bytes, story_id)
    append_fallback_reasons(result: result, fallback_reasons: fallback_reasons)
  rescue StandardError => e
    empty_result("transcription_error", stderr: e.message, fallback_reasons: fallback_reasons)
  end

  private

  def transcribe_with_microservice(audio_bytes, story_id)
    started_at = monotonic_started_at
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
      http.open_timeout = MICROSERVICE_OPEN_TIMEOUT_SECONDS
      http.read_timeout = MICROSERVICE_READ_TIMEOUT_SECONDS
      
      request = Net::HTTP::Post.new(uri.request_uri)
      request["Content-Type"] = "multipart/form-data; boundary=#{boundary}"
      request["Accept"] = "application/json"
      request.body = post_body.join
      
      response = http.request(request)
      body = JSON.parse(response.body.to_s.presence || "{}")
      
      if response.is_a?(Net::HTTPSuccess) && body["success"]
        self.class.clear_microservice_backoff!
        Ai::ApiUsageTracker.track_success(
          provider: "local_microservice",
          operation: "transcribe_audio",
          category: "other",
          started_at: started_at,
          http_status: response.code.to_i,
          metadata: {
            source: "speech_transcription_service",
            model: @whisper_model,
            story_id: story_id.to_s
          }
        )
        {
          transcript: body["transcript"],
          metadata: {
            source: "local_microservice",
            model: @whisper_model,
            confidence: body.dig("metadata", "confidence")
          }
        }
      else
        self.class.mark_microservice_backoff!(
          reason: "HTTP #{response.code}: #{body.dig('error').to_s.presence || body['detail'].to_s.presence || 'transcription_failed'}"
        )
        Ai::ApiUsageTracker.track_failure(
          provider: "local_microservice",
          operation: "transcribe_audio",
          category: "other",
          started_at: started_at,
          http_status: response.code.to_i,
          error: body.dig("error").to_s.presence || "microservice_transcription_failed",
          metadata: {
            source: "speech_transcription_service",
            model: @whisper_model,
            story_id: story_id.to_s
          }
        )
        empty_result("microservice_error", stderr: body.dig("error"))
      end
    end
  rescue StandardError => e
    self.class.mark_microservice_backoff!(reason: "#{e.class}: #{e.message}")
    Ai::ApiUsageTracker.track_failure(
      provider: "local_microservice",
      operation: "transcribe_audio",
      category: "other",
      started_at: started_at || monotonic_started_at,
      error: "#{e.class}: #{e.message}",
      metadata: {
        source: "speech_transcription_service",
        model: @whisper_model,
        story_id: story_id.to_s
      }
    )
    empty_result("microservice_error", stderr: e.message)
  end

  def transcribe_with_binary(audio_bytes, story_id)
    started_at = monotonic_started_at
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

        Ai::ApiUsageTracker.track_success(
          provider: "local_whisper_binary",
          operation: "transcribe_audio",
          category: "other",
          started_at: started_at,
          metadata: {
            source: "speech_transcription_service",
            model: @whisper_model,
            story_id: story_id.to_s
          }
        )

        {
          transcript: text,
          metadata: {
            source: "local_whisper_binary",
            model: @whisper_model
          }
        }
      end
    end
  rescue StandardError => e
    Ai::ApiUsageTracker.track_failure(
      provider: "local_whisper_binary",
      operation: "transcribe_audio",
      category: "other",
      started_at: started_at || monotonic_started_at,
      error: "#{e.class}: #{e.message}",
      metadata: {
        source: "speech_transcription_service",
        model: @whisper_model,
        story_id: story_id.to_s
      }
    )
    raise
  end

  def command_available?(command)
    system("command -v #{Shellwords.escape(command)} >/dev/null 2>&1")
  end

  def append_fallback_reasons(result:, fallback_reasons:)
    payload = result.is_a?(Hash) ? result.dup : {}
    metadata = payload[:metadata].is_a?(Hash) ? payload[:metadata].dup : {}
    reasons = Array(fallback_reasons).map(&:to_s).map(&:strip).reject(&:blank?).uniq
    return payload if reasons.empty?

    metadata[:fallback_reasons] = reasons
    payload[:metadata] = metadata
    payload
  rescue StandardError
    result
  end

  def empty_result(reason, stderr: nil, fallback_reasons: nil)
    reasons = Array(fallback_reasons).map(&:to_s).map(&:strip).reject(&:blank?).uniq
    {
      transcript: nil,
      metadata: {
        source: "local_whisper",
        reason: reason,
        stderr: stderr.to_s.presence,
        fallback_reasons: reasons.presence
      }.compact
    }
  end

  def monotonic_started_at
    Process.clock_gettime(Process::CLOCK_MONOTONIC)
  rescue StandardError
    Time.current.to_f
  end
end
