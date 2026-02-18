require "test_helper"

module Ai
  module Providers
    class LocalProviderResilienceTest < ActiveSupport::TestCase
      class StubLocalProvider < LocalProvider
        attr_accessor :image_error, :video_error, :comment_error

        private

        def analyze_image_media(_media)
          raise image_error if image_error

          {
            "labelAnnotations" => [
              { "description" => "person" }
            ],
            "textAnnotations" => []
          }
        end

        def analyze_video_media(_media)
          raise video_error if video_error

          {
            "response" => {
              "annotationResults" => [
                {
                  "segmentLabelAnnotations" => []
                }
              ]
            }
          }
        end

        def generate_engagement_comments(post_payload:, image_description:, labels:, author_type:)
          raise comment_error if comment_error

          {
            model: "mistral:7b",
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

      test "image analysis errors fall back instead of failing the full post analysis" do
        provider = StubLocalProvider.new
        provider.image_error = Net::ReadTimeout.new("timed out")

        result = provider.analyze_post!(
          post_payload: post_payload,
          media: { type: "image", bytes: "img" }
        )

        analysis = result[:analysis]
        assert_equal "ok", analysis["comment_generation_status"]
        assert_includes analysis["topics"], "image_analysis_error:Net::ReadTimeout"
      end

      test "comment generation errors degrade to fallback suggestions" do
        provider = StubLocalProvider.new
        provider.comment_error = Net::ReadTimeout.new("timed out")

        result = provider.analyze_post!(
          post_payload: post_payload,
          media: { type: "none" }
        )

        analysis = result[:analysis]
        assert_equal "error_fallback", analysis["comment_generation_status"]
        assert analysis["comment_generation_fallback_used"]
        assert_operator analysis["comment_suggestions"].length, :>=, 3
      end

      private

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
  end
end
