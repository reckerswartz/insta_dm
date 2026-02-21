require "rails_helper"

RSpec.describe "VideoFrameChangeDetectorServiceTest" do
  class StubVideoMetadataService
    def initialize(duration_seconds:)
      @duration_seconds = duration_seconds
    end

    def probe(**)
      {
        duration_seconds: @duration_seconds,
        metadata: { source: "stub_probe" }
      }
    end
  end

  class StubDetector < VideoFrameChangeDetectorService
    attr_accessor :gray_frames, :jpeg_frame

    private

    def command_available?(_command)
      true
    end

    def sample_timestamps(duration_seconds:)
      [ 0.0, 1.0, 2.0 ]
    end

    def extract_grayscale_frame(video_path:, timestamp_seconds:)
      gray_frames.shift
    end

    def extract_jpeg_frame(video_path:, timestamp_seconds:)
      jpeg_frame
    end
  end
  it "classifies static video when sampled frames barely change" do
    detector = StubDetector.new(
      video_metadata_service: StubVideoMetadataService.new(duration_seconds: 3.0)
    )
    detector.gray_frames = [
      ([ 16 ].pack("C") * 1024),
      ([ 17 ].pack("C") * 1024),
      ([ 16 ].pack("C") * 1024)
    ]
    detector.jpeg_frame = "jpeg-bytes"

    result = detector.classify(video_bytes: "video", reference_id: "static", content_type: "video/mp4")

    assert_equal true, result[:static]
    assert_equal "static_image", result[:processing_mode]
    assert_equal "jpeg-bytes", result[:frame_bytes]
    assert_equal "image/jpeg", result[:frame_content_type]
  end
  it "classifies dynamic video when sampled frames differ significantly" do
    detector = StubDetector.new(
      video_metadata_service: StubVideoMetadataService.new(duration_seconds: 3.0)
    )
    detector.gray_frames = [
      ([ 0 ].pack("C") * 1024),
      ([ 255 ].pack("C") * 1024),
      ([ 0 ].pack("C") * 1024)
    ]
    detector.jpeg_frame = "jpeg-bytes"

    result = detector.classify(video_bytes: "video", reference_id: "dynamic", content_type: "video/mp4")

    assert_equal false, result[:static]
    assert_equal "dynamic_video", result[:processing_mode]
    assert_equal "jpeg-bytes", result[:frame_bytes]
  end

  it "handles binary grayscale samples without UTF-8 errors" do
    detector = StubDetector.new(
      video_metadata_service: StubVideoMetadataService.new(duration_seconds: 3.0)
    )
    invalid_utf8 = ([ 255 ].pack("C") * 1024).force_encoding("UTF-8")
    detector.gray_frames = [
      invalid_utf8,
      ([ 0 ].pack("C") * 1024).force_encoding("UTF-8"),
      invalid_utf8
    ]
    detector.jpeg_frame = "jpeg-bytes"

    result = detector.classify(video_bytes: "video", reference_id: "binary", content_type: "video/mp4")

    expect(result[:processing_mode]).to be_in(%w[static_image dynamic_video])
    expect(result[:frame_bytes]).to eq("jpeg-bytes")
  end
end
