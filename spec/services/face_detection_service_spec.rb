require "rails_helper"

RSpec.describe "FaceDetectionServiceTest" do
  it "filters zero confidence faces and deduplicates overlapping detections" do
    fake_client = Class.new do
      def detect_faces_and_ocr!(image_bytes:, usage_context:)
        {
          "faces" => [
            { "confidence" => 0.0, "bbox" => [ 10, 10, 60, 60 ] },
            { "confidence" => 0.93, "bbox" => [ 10, 10, 60, 60 ] },
            { "confidence" => 0.91, "bbox" => [ 11, 11, 61, 61 ] },
            { "confidence" => 0.22, "bbox" => [ 120, 120, 180, 180 ] }
          ],
          "metadata" => { "source" => "test-client" }
        }
      end
    end.new

    service = FaceDetectionService.new(client: fake_client, min_face_confidence: 0.25)
    result = service.detect(media_payload: { story_id: "post:123", image_bytes: "img-bytes" })

    assert_equal 1, result[:faces].length
    assert_equal 0.93, result[:faces].first[:confidence]
    assert_equal 4, result.dig(:metadata, :detected_face_count)
    assert_equal 2, result.dig(:metadata, :filtered_face_count)
    assert_equal 3, result.dig(:metadata, :dropped_face_count)
  end
end
