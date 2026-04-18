require "rails_helper"

RSpec.describe Ai::ProviderRegistry do
  # Phase 4.2 made nvidia rows auto-enable when a Rails credential key
  # is present. The dev environment's credentials file carries such a
  # key, which would pollute every spec with enabled nvidia rows. Force
  # the "no credentials" path globally so specs stay deterministic
  # (individual examples that need the key-present branch stub it back).
  before do
    allow(Rails.application.credentials).to receive(:dig).and_call_original
    allow(Rails.application.credentials).to receive(:dig).with(:nvidia, :api_key).and_return(nil)
  end

  it "creates default provider settings when missing" do
    AiProviderSetting.where(provider: "local").delete_all

    expect do
      described_class.ensure_settings!
    end.to change { AiProviderSetting.where(provider: "local").count }.by(1)

    setting = AiProviderSetting.find_by!(provider: "local")
    expect(setting.enabled).to eq(true)
    expect(setting.priority).to eq(20)
  end

  it "returns only enabled provider settings" do
    described_class.ensure_settings!
    setting = AiProviderSetting.find_by!(provider: "local")

    setting.update!(enabled: false)
    expect(described_class.enabled_settings).to eq([])

    setting.update!(enabled: true, priority: 5)
    enabled = described_class.enabled_settings
    expect(enabled.map(&:provider)).to eq([ "local" ])
    expect(enabled.first.priority).to eq(5)
  end

  it "returns provider settings in enabled-first order, including nvidia role rows" do
    described_class.ensure_settings!

    settings = described_class.all_settings
    expect(settings.map(&:provider)).to include("local", "nvidia")

    local_row = settings.find { |s| s.provider == "local" }
    expect(local_row.enabled).to eq(true)

    nvidia_rows = settings.select { |s| s.provider == "nvidia" }
    expect(nvidia_rows.map(&:role)).to match_array(AiProviderSetting::ROLES)
  end

  it "prioritizes nvidia over local so Ai::Runner tries NVIDIA first" do
    described_class.ensure_settings!

    local_priority = AiProviderSetting.for_provider("local").first.priority
    nvidia_priorities = AiProviderSetting.for_provider("nvidia").pluck(:priority)

    expect(nvidia_priorities).to all(be < local_priority),
      "Expected every nvidia priority (#{nvidia_priorities.inspect}) to be lower than local (#{local_priority})"
  end

  it "auto-enables nvidia rows when a shared credential api_key is present" do
    allow(Rails.application.credentials).to receive(:dig).with(:nvidia, :api_key).and_return("nvapi-test")

    AiProviderSetting.where(provider: "nvidia").delete_all
    described_class.ensure_settings!

    expect(AiProviderSetting.for_provider("nvidia")).to all(have_attributes(enabled: true))
  end

  it "leaves nvidia rows disabled when no credential api_key is configured" do
    # Outer `before` block already stubs dig(:nvidia, :api_key) to nil.
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
    setting = AiProviderSetting.find_or_create_by!(provider: "local") do |row|
      row.enabled = true
      row.priority = 1
    end

    provider = described_class.build_provider("local", setting: setting)

    expect(provider).to be_a(Ai::Providers::LocalProvider)
    expect(provider.setting).to eq(setting)
    expect(provider.key).to eq("local")
  end

  it "raises for unsupported providers" do
    expect do
      described_class.build_provider("unsupported")
    end.to raise_error(RuntimeError, /Unsupported AI provider/)
  end
end
