require "open3"
require "shellwords"
require "tempfile"

class VideoFrameChangeDetectorService
  DEFAULT_SAMPLE_FRAMES = 3
  DEFAULT_DIFF_THRESHOLD = 2.5
  GRAYSCALE_WIDTH = 32
  GRAYSCALE_HEIGHT = 32

  def initialize(
    ffmpeg_bin: nil,
    sample_frames: nil,
    diff_threshold: nil,
    video_metadata_service: VideoMetadataService.new
  )
    resolved_bin = ffmpeg_bin.to_s.presence || ENV["FFMPEG_BIN"].to_s.presence || default_ffmpeg_bin
    @ffmpeg_bin = resolved_bin.to_s
    @sample_frames = sample_frames.to_i.positive? ? sample_frames.to_i : DEFAULT_SAMPLE_FRAMES
    @diff_threshold = diff_threshold.to_f.positive? ? diff_threshold.to_f : DEFAULT_DIFF_THRESHOLD
    @video_metadata_service = video_metadata_service
  end

  def classify(video_bytes:, reference_id:, content_type: nil)
    return empty_result(reason: "video_bytes_missing") if video_bytes.blank?
    return empty_result(reason: "ffmpeg_missing") unless command_available?(@ffmpeg_bin)

    Tempfile.create([ "video_change_detect_#{reference_id}", extension_for(content_type: content_type) ]) do |video_file|
      video_file.binmode
      video_file.write(video_bytes)
      video_file.flush

      probe = @video_metadata_service.probe(
        video_bytes: video_bytes,
        story_id: reference_id,
        content_type: content_type
      )
      duration_seconds = probe[:duration_seconds]
      timestamps = sample_timestamps(duration_seconds: duration_seconds)

      samples = timestamps.filter_map do |timestamp|
        gray = extract_grayscale_frame(video_path: video_file.path, timestamp_seconds: timestamp)
        next if gray.nil? || gray.bytesize.zero?

        {
          timestamp_seconds: timestamp,
          gray_bytes: gray
        }
      end

      primary_timestamp = samples.first&.dig(:timestamp_seconds) || 0.0
      representative_frame = extract_jpeg_frame(video_path: video_file.path, timestamp_seconds: primary_timestamp)
      return empty_result(
        reason: "insufficient_sample_frames",
        frame_bytes: representative_frame,
        duration_seconds: duration_seconds,
        metadata: {
          sampled_timestamps: timestamps,
          sampled_frames: samples.length,
          video_probe: probe[:metadata]
        }
      ) if samples.length < 2

      diffs = compute_frame_diffs(samples: samples)
      max_diff = diffs.max.to_f
      avg_diff = (diffs.sum.to_f / diffs.length.to_f).round(4)
      static = max_diff <= @diff_threshold

      {
        static: static,
        processing_mode: static ? "static_image" : "dynamic_video",
        frame_bytes: representative_frame,
        frame_content_type: representative_frame.present? ? "image/jpeg" : nil,
        duration_seconds: duration_seconds,
        metadata: {
          sampled_timestamps: samples.map { |row| row[:timestamp_seconds] },
          sampled_frames: samples.length,
          diff_threshold: @diff_threshold,
          max_mean_diff: max_diff.round(4),
          avg_mean_diff: avg_diff,
          frame_diffs: diffs.map { |value| value.round(4) },
          video_probe: probe[:metadata]
        }
      }
    end
  rescue StandardError => e
    empty_result(
      reason: "frame_change_detection_error",
      metadata: {
        error_class: e.class.name,
        error_message: e.message.to_s
      }
    )
  end

  private

  def sample_timestamps(duration_seconds:)
    duration = duration_seconds.to_f
    return [ 0.0, 0.8, 1.6 ].first(@sample_frames).uniq if duration <= 0.0

    last = [ duration - 0.12, 0.0 ].max
    middle = duration / 2.0
    points = [ 0.0, middle, last ].first(@sample_frames).map { |value| value.round(3) }.uniq
    while points.length < [ @sample_frames, 2 ].max
      points << (points.last.to_f + 0.5).round(3)
      points = points.uniq
    end
    points
  end

  def extract_grayscale_frame(video_path:, timestamp_seconds:)
    cmd = [
      @ffmpeg_bin,
      "-hide_banner",
      "-loglevel",
      "error",
      "-ss",
      format("%.3f", timestamp_seconds.to_f),
      "-i",
      video_path.to_s,
      "-frames:v",
      "1",
      "-vf",
      "scale=#{GRAYSCALE_WIDTH}:#{GRAYSCALE_HEIGHT},format=gray",
      "-f",
      "rawvideo",
      "-pix_fmt",
      "gray",
      "pipe:1"
    ]
    stdout, _stderr, status = Open3.capture3(*cmd)
    stdout = stdout.to_s.b
    return nil unless status.success?
    return nil unless stdout.bytesize == (GRAYSCALE_WIDTH * GRAYSCALE_HEIGHT)

    stdout
  rescue StandardError
    nil
  end

  def extract_jpeg_frame(video_path:, timestamp_seconds:)
    cmd = [
      @ffmpeg_bin,
      "-hide_banner",
      "-loglevel",
      "error",
      "-ss",
      format("%.3f", timestamp_seconds.to_f),
      "-i",
      video_path.to_s,
      "-frames:v",
      "1",
      "-q:v",
      "2",
      "-f",
      "image2pipe",
      "-vcodec",
      "mjpeg",
      "pipe:1"
    ]
    stdout, _stderr, status = Open3.capture3(*cmd)
    stdout = stdout.to_s.b
    return nil unless status.success?
    return nil if stdout.bytesize.zero?

    stdout
  rescue StandardError
    nil
  end

  def compute_frame_diffs(samples:)
    list = Array(samples)
    return [] if list.length < 2

    baseline = list.first[:gray_bytes]
    diffs = []
    list.drop(1).each do |row|
      diffs << mean_abs_diff(baseline, row[:gray_bytes])
    end
    list.each_cons(2) do |previous, current|
      diffs << mean_abs_diff(previous[:gray_bytes], current[:gray_bytes])
    end
    diffs
  end

  def mean_abs_diff(bytes_a, bytes_b)
    a = bytes_a.to_s
    b = bytes_b.to_s
    length = [ a.bytesize, b.bytesize ].min
    return 255.0 if length <= 0

    total = 0
    length.times do |index|
      total += (a.getbyte(index).to_i - b.getbyte(index).to_i).abs
    end
    total.to_f / length.to_f
  end

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

  def empty_result(reason:, frame_bytes: nil, duration_seconds: nil, metadata: {})
    {
      static: nil,
      processing_mode: "dynamic_video",
      frame_bytes: frame_bytes,
      frame_content_type: frame_bytes.present? ? "image/jpeg" : nil,
      duration_seconds: duration_seconds,
      metadata: {
        reason: reason
      }.merge(metadata.to_h)
    }
  end
end
