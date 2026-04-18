require "rails_helper"

RSpec.describe AiProviderSetting do
  it "normalizes config access and supports config updates" do
    setting = described_class.find_or_initialize_by(provider: "nvidia", role: "text_quality")
    setting.enabled = true
    setting.priority = 1
    setting.config = { model: "meta/llama-3.3-70b-instruct" }
    setting.save!

    expect(setting.config_hash).to eq({ "model" => "meta/llama-3.3-70b-instruct" })
    expect(setting.config_value(:model)).to eq("meta/llama-3.3-70b-instruct")

    setting.set_config_value(:temperature, "0.2")
    expect(setting.config_hash).to include("temperature" => "0.2")

    setting.set_config_value(:temperature, nil)
    expect(setting.config_hash).not_to have_key("temperature")
  end

  it "returns sensible display and effective values" do
    setting = described_class.new(provider: "nvidia", role: "text_quality", enabled: true, priority: 1, config: {})
    expect(setting.display_name).to eq("NVIDIA Build (Text quality)")
    expect(setting.effective_api_key).to eq(Rails.application.credentials.dig(:nvidia, :api_key).to_s)

    setting.api_key = "secret"
    setting.set_config_value(:model, "meta/llama-3.3-70b-instruct")
    expect(setting.effective_api_key).to eq("secret")
    expect(setting.api_key_present?).to eq(true)
    expect(setting.effective_model).to eq("meta/llama-3.3-70b-instruct")
  end

  it "validates provider inclusion, uniqueness, and priority" do
    existing = described_class.find_or_create_by!(provider: "nvidia", role: "text_quality") do |row|
      row.enabled = true
      row.priority = 1
    end

    duplicate = described_class.new(provider: "nvidia", role: "text_quality", enabled: false, priority: 2)
    expect(duplicate.valid?).to eq(false)
    expect(duplicate.errors[:provider]).to be_present

    unsupported = described_class.new(provider: "local", role: nil, enabled: true, priority: 1)
    expect(unsupported.valid?).to eq(false)
    expect(unsupported.errors[:provider]).to be_present

    unsupported_external = described_class.new(provider: "external", role: nil, enabled: true, priority: 1)
    expect(unsupported_external.valid?).to eq(false)
    expect(unsupported_external.errors[:provider]).to be_present

    invalid_priority = existing.dup
    invalid_priority.role = "text_fast"
    invalid_priority.priority = -1
    invalid_priority.validate
    expect(invalid_priority.errors[:priority]).to be_present
  end

  it "requires a role on multi-role providers like nvidia" do
    missing_role = described_class.new(provider: "nvidia", role: nil, enabled: true, priority: 1)
    expect(missing_role.valid?).to eq(false)
    expect(missing_role.errors[:role]).to be_present
  end
end
