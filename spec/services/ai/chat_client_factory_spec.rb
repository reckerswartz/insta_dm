require "rails_helper"

RSpec.describe Ai::ChatClientFactory do
  before do
    allow(Rails.application.credentials).to receive(:dig).and_call_original
    allow(Rails.application.credentials).to receive(:dig).with(:nvidia, :api_key).and_return(nil)
    Ai::ProviderRegistry.ensure_settings!
  end

  it "returns Ai::OllamaClient when no nvidia row is enabled with a key" do
    AiProviderSetting.for_provider("nvidia").update_all(enabled: false, api_key: nil)
    expect(described_class.build).to be_a(Ai::OllamaClient)
  end

  it "returns Ai::NvidiaOllamaCompatClient once any text role has a key and is enabled" do
    AiProviderSetting.for_provider("nvidia")
                     .for_role("text_quality").first!
                     .update!(enabled: true, api_key: "nvapi-test")

    expect(described_class.build).to be_a(Ai::NvidiaOllamaCompatClient)
  end

  it "returns Ai::OllamaClient when only embedding has a key (embedding is not a text role)" do
    AiProviderSetting.for_provider("nvidia").update_all(enabled: false, api_key: nil)
    AiProviderSetting.for_provider("nvidia")
                     .for_role("embedding").first!
                     .update!(enabled: true, api_key: "nvapi-test")

    expect(described_class.build).to be_a(Ai::OllamaClient)
  end
end
