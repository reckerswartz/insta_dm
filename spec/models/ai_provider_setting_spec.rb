require "rails_helper"

RSpec.describe AiProviderSetting do
  it "normalizes config access and supports config updates" do
    setting = described_class.find_or_initialize_by(provider: "local")
    setting.enabled = true
    setting.priority = 1
    setting.config = { model: "llama3.2-vision:11b" }
    setting.save!

    expect(setting.config_hash).to eq({ "model" => "llama3.2-vision:11b" })
    expect(setting.config_value(:model)).to eq("llama3.2-vision:11b")

    setting.set_config_value(:temperature, "0.2")
    expect(setting.config_hash).to include("temperature" => "0.2")

    setting.set_config_value(:temperature, nil)
    expect(setting.config_hash).not_to have_key("temperature")
  end

  it "returns sensible display and effective values" do
    setting = described_class.new(provider: "local", enabled: true, priority: 1, config: {})
    expect(setting.display_name).to eq("Local AI Microservice")
    expect(setting.effective_api_key).to eq("")
    expect(setting.api_key_present?).to eq(false)
    expect(setting.effective_model).to eq("")

    setting.api_key = "secret"
    setting.set_config_value(:model, "llama3.1")
    expect(setting.effective_api_key).to eq("secret")
    expect(setting.api_key_present?).to eq(true)
    expect(setting.effective_model).to eq("llama3.1")
  end

  it "validates provider inclusion, uniqueness, and priority" do
    existing = described_class.find_or_create_by!(provider: "local") do |row|
      row.enabled = true
      row.priority = 1
    end

    duplicate = described_class.new(provider: "local", enabled: false, priority: 2)
    expect(duplicate.valid?).to eq(false)
    expect(duplicate.errors[:provider]).to be_present

    unsupported = described_class.new(provider: "external", enabled: true, priority: 1)
    expect(unsupported.valid?).to eq(false)
    expect(unsupported.errors[:provider]).to be_present

    invalid_priority = existing.dup
    invalid_priority.priority = -1
    invalid_priority.validate
    expect(invalid_priority.errors[:priority]).to be_present
  end
end
