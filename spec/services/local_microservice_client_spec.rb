require "rails_helper"

RSpec.describe "LocalMicroserviceClientTest" do
  class StubClient < Ai::LocalMicroserviceClient
    attr_writer :stub_response

    private

    def upload_file(_endpoint, _file_path, _params = {})
      @stub_response
    end
  end
  it "detect_faces_and_ocr normalizes labels text tags and faces" do
    client = StubClient.new(service_url: "http://example.test")
    client.stub_response = {
      "results" => {
        "text" => [ { "text" => "Deal now @Creator #Promo" } ],
        "labels" => [ { "label" => "Person" }, { "description" => "Clock" } ],
        "faces" => [ { "confidence" => 0.88, "bbox" => [ 1, 2, 11, 22 ] } ]
      }
    }

    payload = client.detect_faces_and_ocr!(image_bytes: "fake-image-bytes", usage_context: { workflow: "test" })

    assert_equal "Deal now @Creator #Promo", payload["ocr_text"]
    assert_equal [ "Person", "Clock" ], payload["content_labels"]
    assert_equal [ "@creator" ], payload["mentions"]
    assert_equal [ "#promo" ], payload["hashtags"]
    assert_equal 1, payload["faces"].length
    assert_equal({ "x1" => 1, "y1" => 2, "x2" => 11, "y2" => 22 }, payload.dig("faces", 0, "bounding_box"))
  end
end
