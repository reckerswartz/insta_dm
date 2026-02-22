require "open3"
require "shellwords"
require "tempfile"
require "tmpdir"

class VideoFrameExtractionService
  include BinaryCommandResolver
  DEFAULT_INTERVAL_SECONDS = 2.0
  DEFAULT_MAX_FRAMES = 12

  def initialize(ffmpeg_bin: nil, interval_seconds: nil, max_frames: nil)
    resolved_bin = ffmpeg_bin.to_s.presence || ENV["FFMPEG_BIN"].to_s.presence || default_ffmpeg_bin
    @ffmpeg_bin = resolve_command_path(resolved_bin)
    @interval_seconds = interval_seconds.to_f.positive? ? interval_seconds.to_f : ENV.fetch("VIDEO_FRAME_INTERVAL_SECONDS", DEFAULT_INTERVAL_SECONDS).to_f
    @max_frames = max_frames.to_i.positive? ? max_frames.to_i : ENV.fetch("VIDEO_MAX_FRAMES", DEFAULT_MAX_FRAMES).to_i
  end

  def extract(
    video_bytes:,
    story_id:,
    content_type: nil,
    interval_seconds: nil,
    max_frames: nil,
    timestamps_seconds: nil,
    key_frames_only: nil
  )
    return empty_result("video_bytes_missing") if video_bytes.blank?
    return empty_result("ffmpeg_missing") unless command_available?(@ffmpeg_bin)

    resolved_interval = normalize_interval_seconds(interval_seconds)
    resolved_max_frames = normalize_max_frames(max_frames)
    timestamp_samples = normalize_timestamps(timestamps_seconds, limit: resolved_max_frames)
    resolved_key_frames_only = resolve_key_frames_only(key_frames_only)

    Tempfile.create([ "story_video_#{story_id}", extension_for(content_type: content_type) ]) do |video_file|
      video_file.binmode
      video_file.write(video_bytes)
      video_file.flush

      Dir.mktmpdir("story_frames_#{story_id}_") do |output_dir|
        if timestamp_samples.any?
          extract_by_timestamps!(
            video_path: video_file.path,
            output_dir: output_dir,
            timestamps_seconds: timestamp_samples,
            key_frames_only: resolved_key_frames_only
          )
        else
          extract_by_interval!(
            video_path: video_file.path,
            output_dir: output_dir,
            interval_seconds: resolved_interval,
            max_frames: resolved_max_frames
          )
        end
      end
    end
  rescue StandardError => e
    empty_result("frame_extraction_error", stderr: e.message)
  end

  private

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

  def extract_by_interval!(video_path:, output_dir:, interval_seconds:, max_frames:)
    pattern = File.join(output_dir, "frame_%05d.jpg")
    fps = format("1/%.2f", [ interval_seconds, 0.2 ].max)
    cmd = [
      @ffmpeg_bin,
      "-hide_banner",
      "-loglevel",
      "error",
      "-i",
      video_path.to_s,
      "-vf",
      "fps=#{fps}",
      "-frames:v",
      max_frames.to_i.to_s,
      "-q:v",
      "2",
      pattern
    ]
    _stdout, stderr, status = Open3.capture3(*cmd)
    return empty_result("ffmpeg_extract_failed", stderr: stderr.to_s) unless status.success?

    files = Dir[File.join(output_dir, "frame_*.jpg")].sort.first(max_frames.to_i)
    frames = files.each_with_index.map do |path, idx|
      {
        index: idx,
        timestamp_seconds: (idx * interval_seconds).round(2),
        image_bytes: File.binread(path)
      }
    end

    {
      frames: frames,
      metadata: {
        source: "ffmpeg",
        sampling_mode: "interval",
        interval_seconds: interval_seconds,
        max_frames: max_frames.to_i,
        extracted_frames: files.length
      }
    }
  end

  def extract_by_timestamps!(video_path:, output_dir:, timestamps_seconds:, key_frames_only:)
    rows = []
    errors = []

    Array(timestamps_seconds).each_with_index do |timestamp, idx|
      output_path = File.join(output_dir, format("frame_%05d.jpg", idx))
      frame = extract_single_frame(
        video_path: video_path,
        output_path: output_path,
        timestamp_seconds: timestamp,
        key_frames_only: key_frames_only
      )
      if frame
        rows << {
          index: rows.length,
          timestamp_seconds: timestamp.round(3),
          image_bytes: frame
        }
      else
        errors << format("timestamp=%.3f", timestamp)
      end
    end

    if rows.empty?
      return empty_result(
        "ffmpeg_extract_failed",
        stderr: errors.first(8).join(", ").presence
      )
    end

    {
      frames: rows,
      metadata: {
        source: "ffmpeg",
        sampling_mode: "timestamp_sampling",
        key_frames_only: key_frames_only,
        requested_timestamps: timestamps_seconds.map { |value| value.round(3) },
        extracted_frames: rows.length,
        dropped_timestamps: errors.length
      }
    }
  end

  def extract_single_frame(video_path:, output_path:, timestamp_seconds:, key_frames_only:)
    if key_frames_only
      keyframe_cmd = ffmpeg_single_frame_cmd(
        video_path: video_path,
        output_path: output_path,
        timestamp_seconds: timestamp_seconds,
        key_frames_only: true
      )
      _stdout, _stderr, status = Open3.capture3(*keyframe_cmd)
      if status.success? && File.exist?(output_path) && File.size(output_path).positive?
        return File.binread(output_path)
      end
    end

    fallback_cmd = ffmpeg_single_frame_cmd(
      video_path: video_path,
      output_path: output_path,
      timestamp_seconds: timestamp_seconds,
      key_frames_only: false
    )
    _stdout, _stderr, status = Open3.capture3(*fallback_cmd)
    return nil unless status.success?
    return nil unless File.exist?(output_path)
    return nil unless File.size(output_path).positive?

    File.binread(output_path)
  rescue StandardError
    nil
  end

  def ffmpeg_single_frame_cmd(video_path:, output_path:, timestamp_seconds:, key_frames_only:)
    cmd = [
      @ffmpeg_bin,
      "-hide_banner",
      "-loglevel",
      "error",
      "-ss",
      format("%.3f", timestamp_seconds.to_f),
      "-i",
      video_path.to_s
    ]
    cmd += [ "-skip_frame", "nokey" ] if key_frames_only
    cmd + [
      "-frames:v",
      "1",
      "-q:v",
      "2",
      output_path.to_s
    ]
  end

  def normalize_interval_seconds(value)
    number = value.to_f
    return @interval_seconds if number <= 0.0

    number.clamp(0.2, 30.0)
  rescue StandardError
    @interval_seconds
  end

  def normalize_max_frames(value)
    number = value.to_i
    return @max_frames if number <= 0

    number.clamp(1, 120)
  rescue StandardError
    @max_frames
  end

  def normalize_timestamps(values, limit:)
    Array(values)
      .map { |row| Float(row) rescue nil }
      .compact
      .map { |value| value.negative? ? 0.0 : value }
      .uniq
      .sort
      .first(limit.to_i)
  rescue StandardError
    []
  end

  def resolve_key_frames_only(value)
    return false if value.nil?

    value == true || value.to_s.strip.downcase.in?(%w[1 true yes on])
  rescue StandardError
    false
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
