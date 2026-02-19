require "open3"
require "shellwords"
require "tempfile"
require "json"

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

      cmd = [
        @ffprobe_bin,
        "-v",
        "error",
        "-show_entries",
        "format=duration:stream=index,codec_type,codec_name,width,height,avg_frame_rate,channels,sample_rate",
        "-of",
        "json",
        video_file.path
      ]
      stdout, stderr, status = Open3.capture3(*cmd)
      return { duration_seconds: nil, metadata: { reason: "ffprobe_failed", stderr: stderr.to_s.presence }.compact } unless status.success?

      parsed = JSON.parse(stdout.to_s.presence || "{}")
      streams = Array(parsed["streams"]).select { |row| row.is_a?(Hash) }
      format = parsed["format"].is_a?(Hash) ? parsed["format"] : {}
      audio_stream = streams.find { |row| row["codec_type"].to_s == "audio" }
      video_stream = streams.find { |row| row["codec_type"].to_s == "video" }
      duration = format["duration"].to_f
      {
        duration_seconds: duration.positive? ? duration.round(2) : nil,
        metadata: {
          source: "ffprobe",
          has_audio: audio_stream.present?,
          audio_codec: audio_stream&.dig("codec_name"),
          channels: audio_stream&.dig("channels"),
          sample_rate_hz: integer_or_nil(audio_stream&.dig("sample_rate")),
          video_codec: video_stream&.dig("codec_name"),
          width: integer_or_nil(video_stream&.dig("width")),
          height: integer_or_nil(video_stream&.dig("height")),
          fps: frame_rate_to_float(video_stream&.dig("avg_frame_rate")),
          stream_count: streams.length
        }.compact
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

  def integer_or_nil(value)
    number = value.to_s.to_i
    number.positive? ? number : nil
  end

  def frame_rate_to_float(value)
    text = value.to_s
    return nil if text.blank?

    if text.include?("/")
      numerator, denominator = text.split("/", 2).map(&:to_f)
      return nil if denominator.to_f <= 0.0

      (numerator / denominator).round(3)
    else
      number = text.to_f
      number.positive? ? number.round(3) : nil
    end
  rescue StandardError
    nil
  end
end
