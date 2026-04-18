require "rails_helper"

RSpec.describe Ai::ChatClientFactory do
  before do
    allow(Rails.application.credentials).to receive(:dig).and_call_original
    allow(Rails.application.credentials).to receive(:dig).with(:nvidia, :api_key).and_return(nil)
    Ai::ProviderRegistry.ensure_settings!
  end

  it "raises NoProviderAvailable when no nvidia row is enabled with a key" do
    AiProviderSetting.for_provider("nvidia").update_all(enabled: false, api_key: nil)
    expect { described_class.build }.to raise_error(described_class::NoProviderAvailable, /NVIDIA provider/)
  end

  it "returns Ai::NvidiaOllamaCompatClient once any text role has a key and is enabled" do
    AiProviderSetting.for_provider("nvidia")
                     .for_role("text_quality").first!
                     .update!(enabled: true, api_key: "nvapi-test")

    expect(described_class.build).to be_a(Ai::NvidiaOllamaCompatClient)
  end

  it "raises NoProviderAvailable when only embedding has a key (embedding is not a text role)" do
    AiProviderSetting.for_provider("nvidia").update_all(enabled: false, api_key: nil)
    AiProviderSetting.for_provider("nvidia")
                     .for_role("embedding").first!
                     .update!(enabled: true, api_key: "nvapi-test")

    expect { described_class.build }.to raise_error(described_class::NoProviderAvailable)
  end

  describe ".nvidia_available?" do
    it "returns false when no nvidia row is enabled with a key" do
      AiProviderSetting.for_provider("nvidia").update_all(enabled: false, api_key: nil)
      expect(described_class.nvidia_available?).to be(false)
    end

    it "returns true once any nvidia text role is enabled with a key" do
      AiProviderSetting.for_provider("nvidia")
                       .for_role("text_fast").first!
                       .update!(enabled: true, api_key: "nvapi-test")

      expect(described_class.nvidia_available?).to be(true)
    end
  end
end
