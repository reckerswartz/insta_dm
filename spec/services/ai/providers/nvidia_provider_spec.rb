require "rails_helper"

RSpec.describe Ai::Providers::NvidiaProvider do
  before { Ai::ProviderRegistry.ensure_settings! }

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

  describe "analyze_* stubs" do
    it "raises NotImplementedError until Phase 4 wires them" do
      provider = described_class.new(setting: AiProviderSetting.for_provider("nvidia").first)
      expect { provider.analyze_profile!(_profile_payload: {}) }
        .to raise_error(NotImplementedError, /Phase 4/)
      expect { provider.analyze_post!(_post_payload: {}) }
        .to raise_error(NotImplementedError, /Phase 4/)
    end
  end
end
