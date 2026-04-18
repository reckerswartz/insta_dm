require "rails_helper"

RSpec.describe Ai::LegacyPipelineConfig do
  describe ".enabled? / .disabled?" do
    around do |ex|
      original = ENV["LEGACY_AI_PIPELINE_ENABLED"]
      begin
        ex.run
      ensure
        ENV["LEGACY_AI_PIPELINE_ENABLED"] = original
      end
    end

    it "defaults to disabled when the env var is unset" do
      ENV.delete("LEGACY_AI_PIPELINE_ENABLED")
      expect(described_class.enabled?).to be(false)
      expect(described_class.disabled?).to be(true)
    end

    it "enables when LEGACY_AI_PIPELINE_ENABLED=true" do
      ENV["LEGACY_AI_PIPELINE_ENABLED"] = "true"
      expect(described_class.enabled?).to be(true)
      expect(described_class.disabled?).to be(false)
    end

    it "enables for boolean-truthy variants" do
      %w[1 t TRUE yes on].each do |truthy|
        ENV["LEGACY_AI_PIPELINE_ENABLED"] = truthy
        expect(described_class.enabled?).to be(true), "expected '#{truthy}' to enable legacy pipeline"
      end
    end

    it "is disabled for empty / false strings" do
      # ActiveModel::Type::Boolean's recognised FALSE_VALUES are
      # ["false","f","0","",nil,false,"off","OFF","FALSE","F"].
      # "no"/"No" are NOT in that set -- treated as truthy -- and have
      # intentionally been left out of this assertion.
      %w[0 false off FALSE].each do |falsey|
        ENV["LEGACY_AI_PIPELINE_ENABLED"] = falsey
        expect(described_class.enabled?).to be(false), "expected '#{falsey}' to disable"
      end

      ENV["LEGACY_AI_PIPELINE_ENABLED"] = ""
      expect(described_class.enabled?).to be(false)
    end
  end

  describe ".skip_result(step:)" do
    it "returns the canonical skipped-step payload" do
      expect(described_class.skip_result(step: :face)).to eq(
        skipped: true,
        reason: "legacy_pipeline_disabled",
        legacy_step: "face",
        deprecated_since: "phase_4_5"
      )
    end
  end
end
