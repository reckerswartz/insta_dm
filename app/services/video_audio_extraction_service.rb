require "open3"
require "shellwords"
require "tempfile"
require "tmpdir"

class VideoAudioExtractionService
  def initialize(ffmpeg_bin: nil)
    resolved_bin = ffmpeg_bin.to_s.presence || ENV["FFMPEG_BIN"].to_s.presence || default_ffmpeg_bin
    @ffmpeg_bin = resolved_bin.to_s
  end

  def extract(video_bytes:, story_id:, content_type: nil)
    return empty_result("video_bytes_missing") if video_bytes.blank?
    return empty_result("ffmpeg_missing") unless command_available?(@ffmpeg_bin)

    Tempfile.create([ "story_video_#{story_id}", extension_for(content_type: content_type) ]) do |video_file|
      video_file.binmode
      video_file.write(video_bytes)
      video_file.flush

      Dir.mktmpdir("story_audio_#{story_id}_") do |output_dir|
        output_path = File.join(output_dir, "audio.wav")
        cmd = [ @ffmpeg_bin, "-hide_banner", "-loglevel", "error", "-i", video_file.path, "-vn", "-ac", "1", "-ar", "16000", "-f", "wav", output_path ]
        _stdout, stderr, status = Open3.capture3(*cmd)
        return empty_result("ffmpeg_audio_extract_failed", stderr: stderr.to_s) unless status.success?
        return empty_result("audio_not_found") unless File.exist?(output_path)

        {
          audio_bytes: File.binread(output_path),
          content_type: "audio/wav",
          metadata: {
            source: "ffmpeg"
          }
        }
      end
    end
  rescue StandardError => e
    empty_result("audio_extraction_error", stderr: e.message)
  end

  private

  def command_available?(command)
    system("command -v #{Shellwords.escape(command)} >/dev/null 2>&1")
  end

  def default_ffmpeg_bin
    local_bin = File.expand_path("~/.local/bin/ffmpeg")
    return local_bin if File.exist?(local_bin)

    "ffmpeg"
  end

  def extension_for(content_type:)
    value = content_type.to_s.downcase
    return ".mp4" if value.include?("mp4")
    return ".mov" if value.include?("quicktime")
    return ".webm" if value.include?("webm")

    ".mp4"
  end

  def empty_result(reason, stderr: nil)
    {
      audio_bytes: nil,
      content_type: nil,
      metadata: {
        source: "ffmpeg",
        reason: reason,
        stderr: stderr.to_s.presence
      }.compact
    }
  end
end
