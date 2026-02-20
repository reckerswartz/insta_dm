require "rails_helper"

RSpec.describe ResponseGenerationService do
  it "uses optimistic templates and injects topic placeholders" do
    engine = instance_double(PersonalizationEngine, build: { tone: "optimistic" })
    service = described_class.new(personalization_engine: engine)
    profile = instance_double(InstagramProfile)

    suggestions = service.generate(
      profile: profile,
      content_understanding: { topics: [ "travel", "fitness" ], sentiment: "neutral" },
      max_suggestions: 3
    )

    expect(suggestions.length).to eq(3)
    expect(suggestions.first).to include("travel")
    expect(suggestions.uniq.length).to eq(suggestions.length)
  end

  it "uses empathetic templates when sentiment is negative regardless of tone" do
    engine = instance_double(PersonalizationEngine, build: { tone: "friendly" })
    service = described_class.new(personalization_engine: engine)
    profile = instance_double(InstagramProfile)

    suggestions = service.generate(
      profile: profile,
      content_understanding: { topics: [], sentiment: "negative" },
      max_suggestions: 5
    )

    expect(suggestions).to include("Sending support your way.")
    expect(suggestions).to include("Rooting for you.")
    expect(suggestions.length).to eq(5)
  end

  it "clamps max suggestions to at least one and removes topic placeholder when missing" do
    engine = instance_double(PersonalizationEngine, build: { tone: "friendly" })
    service = described_class.new(personalization_engine: engine)
    profile = instance_double(InstagramProfile)

    suggestions = service.generate(
      profile: profile,
      content_understanding: { topics: [], sentiment: "neutral" },
      max_suggestions: 0
    )

    expect(suggestions.length).to eq(1)
    expect(suggestions.first).not_to include("{topic}")
  end
end
