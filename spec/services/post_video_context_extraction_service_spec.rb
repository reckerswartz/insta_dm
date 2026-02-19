require "rails_helper"

RSpec.describe "PostVideoContextExtractionServiceTest" do
  class StubFrameChangeDetector
    attr_reader :calls

    def initialize(result:)
      @result = result
      @calls = 0
    end

    def classify(**_kwargs)
      @calls += 1
      @result
    end
  end

  class StubVideoMetadataProbe
    attr_reader :calls

    def initialize(result:)
      @result = result
      @calls = 0
    end

    def probe(**_kwargs)
      @calls += 1
      @result
    end
  end

  class StubAudioExtractor
    attr_reader :calls

    def initialize(result:)
      @result = result
      @calls = 0
    end

    def extract(**_kwargs)
      @calls += 1
      @result
    end
  end

  class StubTranscriber
    attr_reader :calls

    def initialize(result:)
      @result = result
      @calls = 0
    end

    def transcribe(**_kwargs)
      @calls += 1
      @result
    end
  end

  class StubLocalVideoClient
    attr_reader :calls

    def initialize(result:, raise_on_call: false)
      @result = result
      @raise_on_call = raise_on_call
      @calls = 0
    end

    def analyze_video_story_intelligence!(**_kwargs)
      @calls += 1
      raise "local intelligence should not run for this case" if @raise_on_call

      @result
    end
  end

  class StubContentUnderstanding
    attr_reader :calls

    def initialize(result:)
      @result = result
      @calls = []
    end

    def build(media_type:, detections:, transcript_text: nil)
      @calls << {
        media_type: media_type,
        detections_count: Array(detections).length,
        transcript_text: transcript_text
      }
      @result
    end
  end

  it "routes static image-like videos through image semantics and keeps audio context" do
    detector = StubFrameChangeDetector.new(
      result: {
        static: true,
        processing_mode: "static_image",
        duration_seconds: 5.4,
        metadata: {
          video_probe: {
            source: "ffprobe",
            has_audio: true
          }
        }
      }
    )
    probe = StubVideoMetadataProbe.new(
      result: {
        duration_seconds: 5.4,
        metadata: { source: "ffprobe", has_audio: true }
      }
    )
    audio = StubAudioExtractor.new(
      result: {
        audio_bytes: "wav-bytes",
        content_type: "audio/wav",
        metadata: { source: "ffmpeg" }
      }
    )
    transcriber = StubTranscriber.new(
      result: {
        transcript: "A single photo with soundtrack",
        metadata: { source: "whisper" }
      }
    )
    local_client = StubLocalVideoClient.new(result: {}, raise_on_call: true)
    understanding = StubContentUnderstanding.new(
      result: {
        topics: [ "portrait", "music" ],
        objects: [ "person" ],
        scenes: [],
        hashtags: [ "#music" ],
        mentions: [ "@artist" ],
        profile_handles: [ "artist.profile" ],
        ocr_text: nil,
        ocr_blocks: []
      }
    )

    service = PostVideoContextExtractionService.new(
      video_frame_change_detector_service: detector,
      video_metadata_service: probe,
      video_audio_extraction_service: audio,
      speech_transcription_service: transcriber,
      local_microservice_client: local_client,
      content_understanding_service: understanding
    )

    result = service.extract(
      video_bytes: "video-binary",
      reference_id: "post_1",
      content_type: "video/mp4"
    )

    assert_equal false, ActiveModel::Type::Boolean.new.cast(result[:skipped])
    assert_equal "static_image", result[:processing_mode]
    assert_equal true, ActiveModel::Type::Boolean.new.cast(result[:static])
    assert_equal "image", result[:semantic_route]
    assert_equal true, ActiveModel::Type::Boolean.new.cast(result[:has_audio])
    assert_equal "A single photo with soundtrack", result[:transcript]
    assert_equal [ "portrait", "music" ], result[:topics]
    assert_equal [ "person" ], result[:objects]
    assert_equal 1, audio.calls
    assert_equal 1, transcriber.calls
    assert_equal 0, local_client.calls
    assert_equal "image", understanding.calls.first[:media_type]
    assert_includes result[:context_summary].to_s.downcase, "static"
  end

  it "routes dynamic videos through video semantics and uses local video intelligence" do
    detector = StubFrameChangeDetector.new(
      result: {
        static: false,
        processing_mode: "dynamic_video",
        duration_seconds: nil,
        metadata: {}
      }
    )
    probe = StubVideoMetadataProbe.new(
      result: {
        duration_seconds: 4.0,
        metadata: { source: "ffprobe", has_audio: false }
      }
    )
    audio = StubAudioExtractor.new(
      result: {
        audio_bytes: nil,
        content_type: nil,
        metadata: { reason: "no_audio_stream" }
      }
    )
    transcriber = StubTranscriber.new(
      result: {
        transcript: nil,
        metadata: { reason: "audio_unavailable" }
      }
    )
    local_client = StubLocalVideoClient.new(
      result: {
        "content_labels" => [ "mountain", "hiking" ],
        "object_detections" => [ { "label" => "person", "confidence" => 0.82 } ],
        "scenes" => [ { "type" => "outdoor", "timestamp" => 1.2 } ],
        "ocr_text" => "#trail @buddy",
        "ocr_blocks" => [ { "text" => "#trail @buddy" } ],
        "mentions" => [ "@buddy" ],
        "hashtags" => [ "#trail" ],
        "profile_handles" => [ "buddy.profile" ],
        "metadata" => { "source" => "stub_video_intel" }
      }
    )
    understanding = StoryContentUnderstandingService.new

    service = PostVideoContextExtractionService.new(
      video_frame_change_detector_service: detector,
      video_metadata_service: probe,
      video_audio_extraction_service: audio,
      speech_transcription_service: transcriber,
      local_microservice_client: local_client,
      content_understanding_service: understanding
    )

    result = service.extract(
      video_bytes: "video-binary",
      reference_id: "post_2",
      content_type: "video/mp4"
    )

    assert_equal false, ActiveModel::Type::Boolean.new.cast(result[:skipped])
    assert_equal "dynamic_video", result[:processing_mode]
    assert_equal false, ActiveModel::Type::Boolean.new.cast(result[:static])
    assert_equal "video", result[:semantic_route]
    assert_equal false, ActiveModel::Type::Boolean.new.cast(result[:has_audio])
    assert_nil result[:transcript]
    assert_equal 1, probe.calls
    assert_equal 1, local_client.calls
    assert_equal 0, audio.calls
    assert_includes result[:topics], "mountain"
    assert_includes result[:hashtags], "#trail"
    assert_includes result[:mentions], "@buddy"
  end
end
