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

    payload = client.detect_faces_and_ocr!(image_bytes: ("fake-image-bytes" * 20), usage_context: { workflow: "test" })

    assert_equal "Deal now @Creator #Promo", payload["ocr_text"]
    assert_equal [ "Person", "Clock" ], payload["content_labels"]
    assert_equal [ "@creator" ], payload["mentions"]
    assert_equal [ "#promo" ], payload["hashtags"]
    assert_equal 1, payload["faces"].length
    assert_equal({ "x1" => 1, "y1" => 2, "x2" => 11, "y2" => 22 }, payload.dig("faces", 0, "bounding_box"))
  end

  it "analyze_image_bytes accepts top-level payloads without success flag" do
    client = StubClient.new(service_url: "http://example.test")
    client.stub_response = {
      "labels" => [ { "label" => "Person", "confidence" => 0.91 } ],
      "text" => [ { "text" => "hello world", "confidence" => 0.87 } ],
      "faces" => [ { "bbox" => [ 3, 4, 13, 24 ], "confidence" => 0.82 } ]
    }

    response = client.analyze_image_bytes!(
      ("fake-image-bytes" * 20),
      features: [ { type: "LABEL_DETECTION" }, { type: "TEXT_DETECTION" }, { type: "FACE_DETECTION" } ]
    )

    assert_equal [ "Person" ], Array(response["labelAnnotations"]).map { |row| row["description"] }
    assert_equal [ "hello world" ], Array(response["textAnnotations"]).map { |row| row["description"] }
    assert_equal 1, Array(response["faceAnnotations"]).length
  end

  it "analyze_image_bytes raises when microservice explicitly reports failure" do
    client = StubClient.new(service_url: "http://example.test")
    client.stub_response = {
      "success" => false,
      "error" => "decoder unavailable"
    }

    error = assert_raises(RuntimeError) do
      client.analyze_image_bytes!(
        ("fake-image-bytes" * 20),
        features: [ { type: "LABEL_DETECTION" } ]
      )
    end

    assert_includes error.message, "decoder unavailable"
  end

  it "rejects invalid tiny image payloads before remote upload" do
    client = StubClient.new(service_url: "http://example.test")
    client.stub_response = { "results" => {} }

    error = assert_raises(ArgumentError) do
      client.analyze_image_bytes!(
        "tiny",
        features: [ { type: "LABEL_DETECTION" } ]
      )
    end

    assert_includes error.message, "image_bytes_too_small"
  end
end
