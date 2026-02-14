require "open3"
require "shellwords"
require "tempfile"
require "tmpdir"

class SpeechTranscriptionService
  def initialize(whisper_bin: ENV.fetch("WHISPER_BIN", "whisper"), whisper_model: ENV.fetch("WHISPER_MODEL", "base"))
    @whisper_bin = whisper_bin.to_s
    @whisper_model = whisper_model.to_s
  end

  def transcribe(audio_bytes:, story_id:)
    return empty_result("audio_bytes_missing") if audio_bytes.blank?
    return empty_result("whisper_missing") unless command_available?(@whisper_bin)

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
            source: "local_whisper",
            model: @whisper_model
          }
        }
      end
    end
  rescue StandardError => e
    empty_result("transcription_error", stderr: e.message)
  end

  private

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
