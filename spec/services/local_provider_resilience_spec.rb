require "rails_helper"

RSpec.describe Ai::Providers::LocalProvider do
  class StubLocalProvider < Ai::Providers::LocalProvider
    attr_accessor :image_error, :video_error, :comment_error, :video_mode_result

    private

    def analyze_image_media(_media, provider_options: {})
      raise image_error if image_error

      {
        "labelAnnotations" => [
          { "description" => "person" }
        ],
        "textAnnotations" => []
      }
    end

    def analyze_video_media(_media, provider_options: {})
      raise video_error if video_error

      {
        "response" => {
          "annotationResults" => [
            {
              "segmentLabelAnnotations" => [
                {
                  "entity" => {
                    "description" => "city"
                  }
                }
              ]
            }
          ]
        }
      }
    end

    def classify_video_processing(_media)
      return video_mode_result if video_mode_result.present?

      super
    end

    def should_run_local_media_preanalysis?(options:)
      true
    end

    def generate_engagement_comments(post_payload:, image_description:, labels:, author_type:)
      raise comment_error if comment_error

      {
        model: "llama3.2-vision:11b",
        prompt: "test",
        raw: {},
        source: "ollama",
        status: "ok",
        fallback_used: false,
        error_message: nil,
        comment_suggestions: [
          "Great post!",
          "Love this.",
          "Nice share."
        ]
      }
    end
  end

  it "image analysis errors skip comment generation when no visual signals are available" do
    provider = StubLocalProvider.new
    provider.image_error = Net::ReadTimeout.new("timed out")

    result = provider.analyze_post!(
      post_payload: post_payload,
      media: { type: "image", bytes: "img" }
    )

    analysis = result[:analysis]
    assert_equal "skipped_no_visual_signals", analysis["comment_generation_status"]
    assert_equal [], analysis["comment_suggestions"]
    assert_equal [], analysis["topics"]
  end

  it "comment generation errors degrade to fallback suggestions when visual signals exist" do
    provider = StubLocalProvider.new
    provider.comment_error = Net::ReadTimeout.new("timed out")

    result = provider.analyze_post!(
      post_payload: post_payload,
      media: { type: "image", bytes: "image-bytes", content_type: "image/jpeg" }
    )

    analysis = result[:analysis]
    assert_equal "error_fallback", analysis["comment_generation_status"]
    assert analysis["comment_generation_fallback_used"]
    assert_operator analysis["comment_suggestions"].length, :>=, 3
  end

  it "static video is analyzed as image frame and skips full video analysis" do
    provider = StubLocalProvider.new
    provider.video_mode_result = {
      processing_mode: "static_image",
      static: true,
      frame_bytes: "frame-bytes",
      frame_content_type: "image/jpeg",
      metadata: { reason: "static_detected_for_test" }
    }
    provider.video_error = RuntimeError.new("video analysis should be skipped for static media")

    result = provider.analyze_post!(
      post_payload: post_payload,
      media: { type: "video", bytes: "video-bytes", content_type: "video/mp4" }
    )

    analysis = result[:analysis]
    assert_equal "static_image", analysis["video_processing_mode"]
    assert_equal true, analysis["video_static_detected"]
    assert_includes analysis["image_description"].to_s.downcase, "static video detected"
    assert_includes analysis["topics"], "person"
  end

  it "dynamic video still uses video analysis path" do
    provider = StubLocalProvider.new
    provider.video_mode_result = {
      processing_mode: "dynamic_video",
      static: false,
      frame_bytes: nil,
      metadata: { reason: "dynamic_detected_for_test" }
    }
    provider.image_error = RuntimeError.new("image analysis should not be used for dynamic videos")

    result = provider.analyze_post!(
      post_payload: post_payload,
      media: { type: "video", bytes: "video-bytes", content_type: "video/mp4" }
    )

    analysis = result[:analysis]
    assert_equal "dynamic_video", analysis["video_processing_mode"]
    assert_equal false, analysis["video_static_detected"]
    assert_includes analysis["topics"], "city"
  end

  it "checks provider health from ollama only" do
    provider = StubLocalProvider.new
    allow(provider).to receive(:ollama_client).and_return(
      instance_double(Ai::OllamaClient, test_connection!: { ok: true, models: [ "llama3.2-vision:11b" ] })
    )
    allow(provider).to receive(:client).and_raise("microservice health check should not run")

    result = provider.test_key!

    assert_equal true, result[:ok]
    assert_equal [ "llama3.2-vision:11b" ], result[:ollama]
  end

  def post_payload
    {
      author_profile: { tags: [] },
      rules: {
        ignore_if_tagged: [],
        prefer_interact_if_tagged: []
      }
    }
  end
end
