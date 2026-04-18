require "rails_helper"

RSpec.describe Ai::NvidiaModelRouter do
  before { Ai::ProviderRegistry.ensure_settings! }

  describe ".resolve!" do
    it "returns the enabled setting for the requested role when a key is present" do
      row = AiProviderSetting.for_provider("nvidia").for_role("text_quality").first!
      row.update!(enabled: true, api_key: "nvapi-test")

      resolved = described_class.resolve!("text_quality")
      expect(resolved).to eq(row)
    end

    it "falls back per DEFAULT_FALLBACKS when the primary is disabled" do
      AiProviderSetting.for_provider("nvidia").update_all(enabled: true, api_key: "nvapi-test")
      AiProviderSetting.for_provider("nvidia").for_role("text_quality").first!
                       .update!(enabled: false)

      fast = AiProviderSetting.for_provider("nvidia").for_role("text_fast").first!
      resolved = described_class.resolve!("text_quality")
      expect(resolved).to eq(fast)
    end

    it "falls back when the primary has no model configured" do
      AiProviderSetting.for_provider("nvidia").update_all(enabled: true, api_key: "nvapi-test")
      AiProviderSetting.for_provider("nvidia").for_role("text_quality").first!
                       .update!(model: nil, config: nil)

      resolved = described_class.resolve!("text_quality")
      expect(resolved.role).to eq("text_fast")
    end

    it "raises UnconfiguredRoleError when no candidate is usable" do
      AiProviderSetting.for_provider("nvidia").update_all(enabled: false)
      expect {
        described_class.resolve!("embedding")
      }.to raise_error(described_class::UnconfiguredRoleError)
    end
  end

  describe ".resolve (non-raising)" do
    it "returns nil instead of raising when unconfigured" do
      AiProviderSetting.for_provider("nvidia").update_all(enabled: false)
      expect(described_class.resolve("embedding")).to be_nil
    end
  end

  describe ".model_for" do
    it "returns the effective_model of the resolved row" do
      row = AiProviderSetting.for_provider("nvidia").for_role("vision_primary").first!
      row.update!(enabled: true, api_key: "nvapi-test", model: "meta/llama-3.2-90b-vision-instruct")

      expect(described_class.model_for("vision_primary")).to eq("meta/llama-3.2-90b-vision-instruct")
    end
  end
end
