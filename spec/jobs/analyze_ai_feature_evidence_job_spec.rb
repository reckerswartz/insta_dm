require "rails_helper"

RSpec.describe AnalyzeAiFeatureEvidenceJob do
  let(:report) do
    {
      days: 14,
      window_start: 14.days.ago,
      window_end: Time.current,
      summary: {},
      rows: []
    }
  end

  before do
    allow(Ops::AiFeatureEvidenceService).to receive(:new).and_return(
      instance_double(Ops::AiFeatureEvidenceService, call: report)
    )
  end

  it "accepts the legacy keyword-arg form (days: 14)" do
    expect do
      described_class.new.perform(days: 14)
    end.not_to raise_error

    expect(Ops::AiFeatureEvidenceService).to have_received(:new).with(days: 14)
  end

  it "accepts the sidekiq-cron positional-hash form ({ days: 14 })" do
    expect do
      described_class.new.perform({ days: 14 })
    end.not_to raise_error

    expect(Ops::AiFeatureEvidenceService).to have_received(:new).with(days: 14)
  end

  it "accepts the sidekiq-cron positional-hash form with string keys" do
    expect do
      described_class.new.perform({ "days" => 14 })
    end.not_to raise_error

    expect(Ops::AiFeatureEvidenceService).to have_received(:new).with(days: 14)
  end

  it "falls back to ENV.AI_FEATURE_EVIDENCE_DAYS when no arg is given" do
    allow(ENV).to receive(:fetch).and_call_original
    allow(ENV).to receive(:fetch).with("AI_FEATURE_EVIDENCE_DAYS", "14").and_return("7")

    described_class.new.perform

    expect(Ops::AiFeatureEvidenceService).to have_received(:new).with(days: 7)
  end
end
