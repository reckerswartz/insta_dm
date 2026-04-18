require "rails_helper"

RSpec.describe Ai::ProviderRegistry do
  # Phase 9 removed LocalProvider. NVIDIA rows auto-enable when a
  # credential key is present; force the "no credentials" path so each
  # spec starts from a deterministic disabled state.
  before do
    allow(Rails.application.credentials).to receive(:dig).and_call_original
    allow(Rails.application.credentials).to receive(:dig).with(:nvidia, :api_key).and_return(nil)
  end

  it "creates default provider settings when missing" do
    AiProviderSetting.where(provider: "nvidia").delete_all

    expect do
      described_class.ensure_settings!
    end.to change { AiProviderSetting.where(provider: "nvidia").count }.from(0).to(AiProviderSetting::ROLES.length)

    AiProviderSetting.for_provider("nvidia").each do |row|
      expect(row.priority).to eq(2)
      expect(row.enabled).to eq(false)
      expect(row.effective_model).to eq(Ai::NvidiaModelRouter::DEFAULT_MODELS.fetch(row.role))
    end
  end

  it "returns only enabled provider settings" do
    described_class.ensure_settings!
    AiProviderSetting.for_provider("nvidia").update_all(enabled: false)
    expect(described_class.enabled_settings).to eq([])

    first = AiProviderSetting.for_provider("nvidia").order(:role).first
    first.update!(enabled: true, priority: 5)

    enabled = described_class.enabled_settings
    expect(enabled.map(&:provider).uniq).to eq(["nvidia"])
    expect(enabled.first.priority).to eq(5)
  end

  it "returns provider settings in enabled-first order with all NVIDIA roles" do
    described_class.ensure_settings!

    settings = described_class.all_settings
    expect(settings.map(&:provider).uniq).to eq(["nvidia"])
    expect(settings.map(&:role)).to match_array(AiProviderSetting::ROLES)
  end

  it "auto-enables nvidia rows when a shared credential api_key is present" do
    allow(Rails.application.credentials).to receive(:dig).with(:nvidia, :api_key).and_return("nvapi-test")

    AiProviderSetting.where(provider: "nvidia").delete_all
    described_class.ensure_settings!

    expect(AiProviderSetting.for_provider("nvidia")).to all(have_attributes(enabled: true))
  end

  it "leaves nvidia rows disabled when no credential api_key is configured" do
    AiProviderSetting.where(provider: "nvidia").delete_all
    described_class.ensure_settings!

    expect(AiProviderSetting.for_provider("nvidia")).to all(have_attributes(enabled: false))
  end

  it "builds an Ai::Providers::NvidiaProvider for the nvidia key" do
    described_class.ensure_settings!
    AiProviderSetting.for_provider("nvidia").update_all(enabled: true)

    provider = described_class.build_provider("nvidia")

    expect(provider).to be_a(Ai::Providers::NvidiaProvider)
    expect(provider.key).to eq("nvidia")
    expect(provider.setting.provider).to eq("nvidia")
  end

  it "builds provider instances for supported keys" do
    described_class.ensure_settings!
    AiProviderSetting.for_provider("nvidia").update_all(enabled: true)

    provider = described_class.build_provider("nvidia")
    expect(provider).to be_a(Ai::Providers::NvidiaProvider)
    expect(provider.key).to eq("nvidia")
  end

  it "raises for unsupported providers" do
    expect do
      described_class.build_provider("unsupported")
    end.to raise_error(RuntimeError, /Unsupported AI provider/)
  end

  it "no longer registers a 'local' provider (Phase 9 teardown)" do
    expect(described_class::PROVIDERS.keys).to eq(%w[nvidia])
    expect(AiProviderSetting::SUPPORTED_PROVIDERS).to eq(%w[nvidia])
  end
end
