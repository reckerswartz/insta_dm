require "open3"
require "shellwords"
require "tempfile"
require "tmpdir"

class VideoFrameExtractionService
  DEFAULT_INTERVAL_SECONDS = 2.0
  DEFAULT_MAX_FRAMES = 24

  def initialize(ffmpeg_bin: ENV.fetch("FFMPEG_BIN", "ffmpeg"), interval_seconds: nil, max_frames: nil)
    @ffmpeg_bin = ffmpeg_bin.to_s
    @interval_seconds = interval_seconds.to_f.positive? ? interval_seconds.to_f : ENV.fetch("VIDEO_FRAME_INTERVAL_SECONDS", DEFAULT_INTERVAL_SECONDS).to_f
    @max_frames = max_frames.to_i.positive? ? max_frames.to_i : ENV.fetch("VIDEO_MAX_FRAMES", DEFAULT_MAX_FRAMES).to_i
  end

  def extract(video_bytes:, story_id:, content_type: nil)
    return empty_result("video_bytes_missing") if video_bytes.blank?
    return empty_result("ffmpeg_missing") unless command_available?(@ffmpeg_bin)

    Tempfile.create([ "story_video_#{story_id}", extension_for(content_type: content_type) ]) do |video_file|
      video_file.binmode
      video_file.write(video_bytes)
      video_file.flush

      Dir.mktmpdir("story_frames_#{story_id}_") do |output_dir|
        pattern = File.join(output_dir, "frame_%05d.jpg")
        fps = format("1/%.2f", [ @interval_seconds, 0.2 ].max)
        cmd = [ @ffmpeg_bin, "-hide_banner", "-loglevel", "error", "-i", video_file.path, "-vf", "fps=#{fps}", "-q:v", "2", pattern ]
        _stdout, stderr, status = Open3.capture3(*cmd)
        return empty_result("ffmpeg_extract_failed", stderr: stderr.to_s) unless status.success?

        files = Dir[File.join(output_dir, "frame_*.jpg")].sort.first(@max_frames)
        frames = files.each_with_index.map do |path, idx|
          {
            index: idx,
            timestamp_seconds: (idx * @interval_seconds).round(2),
            image_bytes: File.binread(path)
          }
        end

        {
          frames: frames,
          metadata: {
            source: "ffmpeg",
            interval_seconds: @interval_seconds,
            extracted_frames: files.length
          }
        }
      end
    end
  rescue StandardError => e
    empty_result("frame_extraction_error", stderr: e.message)
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

  def empty_result(reason, stderr: nil)
    {
      frames: [],
      metadata: {
        source: "ffmpeg",
        reason: reason,
        stderr: stderr.to_s.presence
      }.compact
    }
  end
end
