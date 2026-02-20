require "rails_helper"

RSpec.describe Ai::ProviderRegistry do
  it "creates default provider settings when missing" do
    AiProviderSetting.where(provider: "local").delete_all

    expect do
      described_class.ensure_settings!
    end.to change { AiProviderSetting.where(provider: "local").count }.by(1)

    setting = AiProviderSetting.find_by!(provider: "local")
    expect(setting.enabled).to eq(true)
    expect(setting.priority).to eq(1)
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

  it "returns provider settings in enabled-first order" do
    described_class.ensure_settings!

    settings = described_class.all_settings
    expect(settings.map(&:provider)).to eq([ "local" ])
    expect(settings.first.enabled).to eq(true)
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
