require "rails_helper"

RSpec.describe Ai::Providers::NvidiaProvider do
  # Phase 4.2: nvidia rows auto-enable when a credential key is present.
  # Force no-credentials so specs start with disabled rows and opt-in
  # explicitly with enable_all_nvidia_rows_with_key!.
  before do
    allow(Rails.application.credentials).to receive(:dig).and_call_original
    allow(Rails.application.credentials).to receive(:dig).with(:nvidia, :api_key).and_return(nil)
    Ai::ProviderRegistry.ensure_settings!
  end

  def enable_all_nvidia_rows_with_key!
    AiProviderSetting.for_provider("nvidia").each do |row|
      row.update!(enabled: true, api_key: "nvapi-test")
    end
  end

  describe "capability flags" do
    subject(:provider) { described_class.new(setting: AiProviderSetting.for_provider("nvidia").first) }

    it "advertises text, image, and video support" do
      expect(provider.key).to eq("nvidia")
      expect(provider.supports_profile?).to be(true)
      expect(provider.supports_post_image?).to be(true)
      expect(provider.supports_post_video?).to be(true)
      expect(provider.requires_api_key?).to be(true)
    end
  end

  describe "#available?" do
    it "is false when no text role is enabled with a key" do
      provider = described_class.new(setting: AiProviderSetting.for_provider("nvidia").first)
      expect(provider.available?).to be(false)
    end

    it "is true once a text role has a key" do
      enable_all_nvidia_rows_with_key!
      provider = described_class.new(setting: AiProviderSetting.for_provider("nvidia").first)
      expect(provider.available?).to be(true)
    end
  end

  describe "#test_key!" do
    it "lists models via Ai::NvidiaClient and returns diagnostics" do
      enable_all_nvidia_rows_with_key!
      stub_request(:get, "https://integrate.api.nvidia.com/v1/models")
        .with(headers: { "Authorization" => "Bearer nvapi-test" })
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: { data: [{ id: "meta/llama-3.3-70b-instruct" }, { id: "meta/llama-3.1-8b-instruct" }] }.to_json
        )

      result = described_class.new(setting: AiProviderSetting.for_provider("nvidia").first).test_key!

      expect(result).to include(ok: true, models_count: 2)
    end

    it "raises when no row is configured" do
      provider = described_class.new(setting: AiProviderSetting.for_provider("nvidia").first)
      expect { provider.test_key! }.to raise_error(/No enabled NVIDIA provider row/)
    end
  end

  describe "#chat!" do
    it "resolves the model via the router and calls the client" do
      enable_all_nvidia_rows_with_key!
      AiProviderSetting.for_provider("nvidia").for_role("text_quality").first
                       .update!(model: "meta/llama-3.3-70b-instruct")

      stub_request(:post, "https://integrate.api.nvidia.com/v1/chat/completions")
        .with(body: hash_including(model: "meta/llama-3.3-70b-instruct"))
        .to_return(status: 200,
                   headers: { "Content-Type" => "application/json" },
                   body: { choices: [{ message: { content: "hi" } }] }.to_json)

      result = described_class.new(setting: AiProviderSetting.for_provider("nvidia").first)
                              .chat!(role: "text_quality",
                                     messages: [{ role: "user", content: "hello" }])

      expect(result.dig("choices", 0, "message", "content")).to eq("hi")
    end
  end

  describe "analyze_profile!" do
    it "calls the text_quality role and coerces the JSON response into the InsightSync-shaped hash" do
      enable_all_nvidia_rows_with_key!

      stub_request(:post, "https://integrate.api.nvidia.com/v1/chat/completions")
        .with(body: hash_including(model: "meta/llama-3.3-70b-instruct", response_format: { "type" => "json_object" }))
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: {
            model: "meta/llama-3.3-70b-instruct",
            choices: [{ message: { content: {
              summary: "Travel creator who posts rooftop photos",
              languages: [{ language: "English", confidence: 0.9, evidence: "bio" }],
              likes: ["rooftop photography", "sunsets"],
              dislikes: [],
              intent_labels: ["friendly"],
              conversation_hooks: [{ hook: "Ask about the last rooftop", evidence: "bio mentions skylines" }],
              personalization_tokens: ["skyline"],
              no_go_zones: [],
              writing_style: { tone: "warm", formality: "casual", emoji_usage: "medium", slang_level: "low", evidence: "short caption cadence" },
              response_style_prediction: "responsive",
              engagement_probability: 0.7,
              recommended_next_action: "comment",
              demographic_estimates: { age: { low: 22, high: 30 }, age_confidence: 0.4, gender: nil, gender_confidence: 0, location: "NYC", location_confidence: 0.5, evidence: "bio says NYC" },
              self_declared: { age: nil, gender: nil, location: "NYC", pronouns: "she/her", other: nil },
              suggested_dm_openers: ["Your last rooftop shot is unreal, where was that taken?"],
              suggested_comment_templates: ["This skyline hits different"],
              confidence_notes: "Clear topic focus",
              why_not_confident: "Limited outgoing message samples"
            }.to_json } }]
          }.to_json
        )

      provider = described_class.new(setting: AiProviderSetting.for_provider("nvidia").first)
      result = provider.analyze_profile!(profile_payload: { username: "skyline_mila", bio: "NYC skylines 🌆", recent_post_captions: [] })

      expect(result[:model]).to eq("meta/llama-3.3-70b-instruct")
      analysis = result[:analysis]
      expect(analysis["summary"]).to eq("Travel creator who posts rooftop photos")
      expect(analysis["likes"]).to include("rooftop photography")
      expect(analysis["suggested_dm_openers"]).not_to be_empty
      expect(analysis["writing_style"]["tone"]).to eq("warm")
      expect(analysis["recommended_next_action"]).to eq("comment")
      expect(result[:prompt][:schema]).to eq("nvidia.profile.v1")
    end

    it "gracefully handles non-JSON model output by returning a default analysis" do
      enable_all_nvidia_rows_with_key!

      stub_request(:post, "https://integrate.api.nvidia.com/v1/chat/completions")
        .to_return(status: 200,
                   headers: { "Content-Type" => "application/json" },
                   body: { choices: [{ message: { content: "Sorry, I can't produce JSON." } }] }.to_json)

      result = described_class.new(setting: AiProviderSetting.for_provider("nvidia").first)
                              .analyze_profile!(profile_payload: { username: "x", bio: "" })

      expect(result[:analysis]).to be_a(Hash)
      # defaults kicked in
      expect(result[:analysis]["summary"]).to be_present
      expect(result[:analysis]["writing_style"]["tone"]).to eq("unknown")
      expect(result[:analysis]["recommended_next_action"]).to eq("review")
    end

    it "strips ```json fenced output defensively" do
      enable_all_nvidia_rows_with_key!
      fenced = "```json\n{\"summary\":\"ok\",\"likes\":[\"photos\"]}\n```"
      stub_request(:post, "https://integrate.api.nvidia.com/v1/chat/completions")
        .to_return(status: 200,
                   headers: { "Content-Type" => "application/json" },
                   body: { choices: [{ message: { content: fenced } }] }.to_json)

      result = described_class.new(setting: AiProviderSetting.for_provider("nvidia").first)
                              .analyze_profile!(profile_payload: { username: "x", bio: "" })

      expect(result[:analysis]["summary"]).to eq("ok")
      expect(result[:analysis]["likes"]).to eq(["photos"])
    end
  end

  describe "analyze_post!" do
    let(:image_bytes) { Base64.decode64("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADUlEQVR42mP8/5+hHgAHggJ/PchI7wAAAABJRU5ErkJggg==") }

    it "uses vision_primary when image bytes are present, sends an image_url content block, and coerces the JSON response" do
      enable_all_nvidia_rows_with_key!

      captured_body = nil
      stub_request(:post, "https://integrate.api.nvidia.com/v1/chat/completions")
        .with { |req| captured_body = JSON.parse(req.body); true }
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: {
            model: "meta/llama-3.2-90b-vision-instruct",
            choices: [{ message: { content: {
              image_description: "A golden retriever running on a beach",
              relevant: true,
              author_type: "personal",
              sentiment: "positive",
              topics: ["dog", "beach", "golden hour"],
              personalization_tokens: ["golden retriever"],
              suggested_actions: ["comment"],
              comment_suggestions: ["That golden hour hits perfectly here"],
              confidence: 0.8,
              engagement_score: 0.75,
              evidence: "visible dog + beach",
              recommended_next_action: "comment"
            }.to_json } }]
          }.to_json
        )

      result = described_class.new(setting: AiProviderSetting.for_provider("nvidia").first)
                              .analyze_post!(
                                post_payload: { caption: "good boy day", owner_username: "beachdog" },
                                media: { type: "image", bytes: image_bytes, content_type: "image/png" }
                              )

      expect(result[:model]).to eq("meta/llama-3.2-90b-vision-instruct")
      expect(result[:prompt][:role]).to eq("vision_primary")
      expect(result[:prompt][:image_count]).to eq(1)
      expect(result[:analysis]["image_description"]).to include("golden retriever")
      expect(result[:analysis]["topics"]).to include("dog")

      # Confirm we actually sent an image_url block rather than plain text.
      sent_content = captured_body.dig("messages", 1, "content")
      expect(sent_content).to be_an(Array)
      image_parts = sent_content.select { |p| p["type"] == "image_url" }
      expect(image_parts.length).to eq(1)
      expect(image_parts.first.dig("image_url", "url")).to start_with("data:image/png;base64,")
    end

    it "falls back to text_quality when no image is present" do
      enable_all_nvidia_rows_with_key!
      stub_request(:post, "https://integrate.api.nvidia.com/v1/chat/completions")
        .with(body: hash_including(model: "meta/llama-3.3-70b-instruct"))
        .to_return(status: 200, headers: { "Content-Type" => "application/json" },
                   body: { choices: [{ message: { content: { image_description: "Image unavailable.", topics: ["travel"] }.to_json } }] }.to_json)

      result = described_class.new(setting: AiProviderSetting.for_provider("nvidia").first)
                              .analyze_post!(post_payload: { caption: "Trip!" })

      expect(result[:prompt][:role]).to eq("text_quality")
      expect(result[:analysis]["image_description"]).to eq("Image unavailable.")
      expect(result[:analysis]["topics"]).to include("travel")
    end
  end
end
