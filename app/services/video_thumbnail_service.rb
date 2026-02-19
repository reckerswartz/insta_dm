require "digest"
require "open3"
require "shellwords"
require "tempfile"

class VideoThumbnailService
  DEFAULT_SEEK_SECONDS = 0.2
  MAX_THUMBNAIL_BYTES = 3 * 1024 * 1024

  def initialize(ffmpeg_bin: nil, seek_seconds: nil)
    resolved_bin = ffmpeg_bin.to_s.presence || ENV["FFMPEG_BIN"].to_s.presence || default_ffmpeg_bin
    @ffmpeg_bin = resolved_bin.to_s
    @seek_seconds = seek_seconds.to_f.positive? ? seek_seconds.to_f : DEFAULT_SEEK_SECONDS
  end

  def extract_first_frame(video_bytes:, reference_id:, content_type: nil)
    return empty_result("video_bytes_missing") if video_bytes.blank?
    return empty_result("ffmpeg_missing") unless command_available?(@ffmpeg_bin)

    Tempfile.create([ "video_thumb_source_#{safe_reference(reference_id)}", extension_for(content_type: content_type) ]) do |video_file|
      video_file.binmode
      video_file.write(video_bytes)
      video_file.flush

      Tempfile.create([ "video_thumb_output_#{safe_reference(reference_id)}", ".jpg" ]) do |thumb_file|
        thumb_file.binmode

        cmd = [
          @ffmpeg_bin,
          "-hide_banner",
          "-loglevel", "error",
          "-ss", format("%.2f", @seek_seconds),
          "-i", video_file.path,
          "-frames:v", "1",
          "-q:v", "3",
          "-f", "image2",
          thumb_file.path
        ]
        _stdout, stderr, status = Open3.capture3(*cmd)
        return empty_result("ffmpeg_extract_failed", stderr: stderr.to_s) unless status.success?

        image_bytes = File.binread(thumb_file.path)
        return empty_result("thumbnail_missing") if image_bytes.blank?
        return empty_result("thumbnail_too_large") if image_bytes.bytesize > MAX_THUMBNAIL_BYTES

        digest = Digest::SHA256.hexdigest("#{reference_id}:#{image_bytes.byteslice(0, 128)}")
        {
          ok: true,
          image_bytes: image_bytes,
          content_type: "image/jpeg",
          filename: "video_thumb_#{digest[0, 12]}.jpg",
          metadata: {
            source: "ffmpeg",
            seek_seconds: @seek_seconds,
            bytes: image_bytes.bytesize
          }
        }
      end
    end
  rescue StandardError => e
    empty_result("thumbnail_extraction_error", stderr: e.message)
  end

  private

  def command_available?(command)
    system("command -v #{Shellwords.escape(command)} >/dev/null 2>&1")
  end

  def safe_reference(value)
    value.to_s.gsub(/[^a-zA-Z0-9_-]/, "_").first(32).presence || "video"
  end

  def default_ffmpeg_bin
    local_bin = File.expand_path("~/.local/bin/ffmpeg")
    return local_bin if File.exist?(local_bin)

    "ffmpeg"
  end

  def extension_for(content_type:)
    value = content_type.to_s.downcase
    return ".mov" if value.include?("quicktime")
    return ".webm" if value.include?("webm")
    return ".mp4" if value.include?("mp4")

    ".mp4"
  end

  def empty_result(reason, stderr: nil)
    {
      ok: false,
      image_bytes: nil,
      content_type: nil,
      filename: nil,
      metadata: {
        source: "ffmpeg",
        reason: reason,
        stderr: stderr.to_s.presence
      }.compact
    }
  end
end
