require "open3"
require "shellwords"
require "tempfile"

class VideoMetadataService
  def initialize(ffprobe_bin: ENV.fetch("FFPROBE_BIN", "ffprobe"))
    @ffprobe_bin = ffprobe_bin.to_s
  end

  def probe(video_bytes:, story_id:, content_type: nil)
    return { duration_seconds: nil, metadata: { reason: "video_bytes_missing" } } if video_bytes.blank?
    return { duration_seconds: nil, metadata: { reason: "ffprobe_missing" } } unless command_available?(@ffprobe_bin)

    Tempfile.create([ "story_probe_#{story_id}", extension_for(content_type: content_type) ]) do |video_file|
      video_file.binmode
      video_file.write(video_bytes)
      video_file.flush

      cmd = [ @ffprobe_bin, "-v", "error", "-show_entries", "format=duration", "-of", "default=noprint_wrappers=1:nokey=1", video_file.path ]
      stdout, stderr, status = Open3.capture3(*cmd)
      return { duration_seconds: nil, metadata: { reason: "ffprobe_failed", stderr: stderr.to_s.presence }.compact } unless status.success?

      duration = stdout.to_s.strip.to_f
      {
        duration_seconds: duration.positive? ? duration.round(2) : nil,
        metadata: { source: "ffprobe" }
      }
    end
  rescue StandardError => e
    { duration_seconds: nil, metadata: { reason: "video_probe_error", stderr: e.message } }
  end

  private

  def command_available?(command)
    system("command -v #{Shellwords.escape(command)} >/dev/null 2>&1")
  end

  def extension_for(content_type:)
    value = content_type.to_s.downcase
    return ".mp4" if value.include?("mp4")
    return ".mov" if value.include?("quicktime")
    return ".webm" if value.include?("webm")

    ".mp4"
  end
end
