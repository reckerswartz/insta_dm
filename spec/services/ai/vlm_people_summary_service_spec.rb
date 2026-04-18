require "rails_helper"

RSpec.describe Ai::VlmPeopleSummaryService do
  before do
    Ai::ProviderRegistry.ensure_settings!
    AiProviderSetting.for_provider("nvidia").update_all(enabled: true, api_key: "nvapi-test")
  end

  let(:png_bytes) { Base64.decode64("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADUlEQVR42mP8/5+hHgAHggJ/PchI7wAAAABJRU5ErkJggg==") }

  def stub_vlm(body_content:)
    stub_request(:post, "https://integrate.api.nvidia.com/v1/chat/completions")
      .to_return(
        status: 200,
        headers: { "Content-Type" => "application/json" },
        body: {
          model: "meta/llama-3.2-90b-vision-instruct",
          choices: [{ message: { role: "assistant", content: body_content } }]
        }.to_json
      )
  end

  describe "#call (happy path)" do
    it "returns a populated Result for { bytes:, content_type: } input" do
      stub_vlm(body_content: {
        people_count: 2,
        descriptions: [
          { index: 0, role: "primary_subject", appearance: "young woman laughing", position: "foreground", expression: "smiling" },
          { index: 1, role: "companion", appearance: "older man in a blue jacket", position: "midground" }
        ],
        prominent_roles: ["creator", "partner"],
        scene: "rooftop brunch"
      }.to_json)

      result = described_class.new.call(image: { bytes: png_bytes, content_type: "image/png" })

      expect(result.ok?).to be(true)
      expect(result.people_count).to eq(2)
      expect(result.descriptions.length).to eq(2)
      expect(result.descriptions.first["appearance"]).to include("young woman")
      expect(result.prominent_roles).to eq(["creator", "partner"])
      expect(result.scene).to eq("rooftop brunch")
    end

    it "accepts a data URL string directly" do
      stub_vlm(body_content: { people_count: 0, descriptions: [], prominent_roles: [], scene: "empty landscape" }.to_json)

      result = described_class.new.call(image: "data:image/png;base64,#{Base64.strict_encode64(png_bytes)}")

      expect(result.ok?).to be(true)
      expect(result.people_count).to eq(0)
      expect(result.descriptions).to eq([])
    end

    it "accepts a remote URL string and forwards it as an image_url content part" do
      captured_body = nil
      stub_request(:post, "https://integrate.api.nvidia.com/v1/chat/completions")
        .with { |req| captured_body = JSON.parse(req.body); true }
        .to_return(status: 200, headers: { "Content-Type" => "application/json" },
                   body: { choices: [{ message: { content: { people_count: 1, descriptions: [{ index: 0, appearance: "one person" }] }.to_json } }] }.to_json)

      described_class.new.call(image: "https://example.com/a.jpg")

      parts = captured_body.dig("messages", 1, "content")
      image_part = parts.find { |p| p["type"] == "image_url" }
      expect(image_part.dig("image_url", "url")).to eq("https://example.com/a.jpg")
    end

    it "clamps people_count to MAX_PEOPLE_CAP and drops descriptions over the cap" do
      descriptions = Array.new(50) { |i| { index: i, appearance: "person #{i}" } }
      stub_vlm(body_content: { people_count: 100, descriptions: descriptions }.to_json)

      result = described_class.new.call(image: { bytes: png_bytes })
      expect(result.people_count).to eq(described_class::MAX_PEOPLE_CAP)
      expect(result.descriptions.length).to eq(described_class::MAX_PEOPLE_CAP)
    end

    it "drops descriptions whose appearance is blank (no hallucinated-filler rows)" do
      stub_vlm(body_content: {
        people_count: 3,
        descriptions: [
          { index: 0, appearance: "ok" },
          { index: 1, appearance: "" },
          { index: 2, role: "background" } # missing appearance
        ]
      }.to_json)

      result = described_class.new.call(image: { bytes: png_bytes })
      expect(result.descriptions.length).to eq(1)
    end
  end

  describe "#call (edge cases)" do
    it "returns ok:false when image is blank" do
      result = described_class.new.call(image: { bytes: nil })
      expect(result.ok?).to be(false)
      expect(result.error).to eq("missing_image")
    end

    it "returns ok:false with non_json_response when the VLM returns prose" do
      stub_vlm(body_content: "Sorry, I can't produce JSON.")
      result = described_class.new.call(image: { bytes: png_bytes })
      expect(result.ok?).to be(false)
      expect(result.error).to eq("non_json_response")
    end

    it "bubbles up auth/rate-limit errors as labelled results (no raise)" do
      stub_request(:post, "https://integrate.api.nvidia.com/v1/chat/completions")
        .to_return(status: 401, body: '{"error":"bad_key"}')

      result = described_class.new.call(image: { bytes: png_bytes })
      expect(result.ok?).to be(false)
      expect(result.error).to start_with("auth:")
    end
  end

  describe "Result#to_h" do
    it "produces the hash downstream callers can store on instagram_post_insights.raw_analysis['people']" do
      result = described_class::Result.new(
        ok: true,
        people_count: 2,
        descriptions: [{ "index" => 0, "appearance" => "x" }],
        prominent_roles: ["creator"],
        scene: "rooftop"
      )
      expect(result.to_h).to eq({
        "ok" => true,
        "people_count" => 2,
        "descriptions" => [{ "index" => 0, "appearance" => "x" }],
        "prominent_roles" => ["creator"],
        "scene" => "rooftop"
      })
    end
  end
end
