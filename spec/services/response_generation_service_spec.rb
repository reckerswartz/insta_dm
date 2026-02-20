require "rails_helper"
require "securerandom"

RSpec.describe ResponseGenerationService do
  class FakeScorer
    def initialize(result)
      @result = result
    end

    def build(current_topics:, image_description:, caption:, limit:)
      @result
    end
  end

  it "uses optimistic templates and injects topic placeholders" do
    engine = instance_double(PersonalizationEngine, build: { tone: "optimistic" })
    service = described_class.new(
      personalization_engine: engine,
      context_signal_scorer_builder: ->(profile:, channel:) { FakeScorer.new({}) }
    )
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
    service = described_class.new(
      personalization_engine: engine,
      context_signal_scorer_builder: ->(profile:, channel:) { FakeScorer.new({}) }
    )
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
    service = described_class.new(
      personalization_engine: engine,
      context_signal_scorer_builder: ->(profile:, channel:) { FakeScorer.new({}) }
    )
    profile = instance_double(InstagramProfile)

    suggestions = service.generate(
      profile: profile,
      content_understanding: { topics: [], sentiment: "neutral" },
      max_suggestions: 0
    )

    expect(suggestions.length).to eq(1)
    expect(suggestions.first).not_to include("{topic}")
  end

  it "reuses scored profile signals when current topics are sparse" do
    account = InstagramAccount.create!(username: "acct_#{SecureRandom.hex(4)}")
    profile = account.instagram_profiles.create!(username: "profile_#{SecureRandom.hex(4)}")
    engine = instance_double(PersonalizationEngine, build: { tone: "friendly", interests: [ "coffee" ] })

    scorer_builder = lambda do |profile:, channel:|
      FakeScorer.new(
        {
          prioritized_signals: [
            { value: "travel" },
            { value: "beach" }
          ],
          engagement_memory: {
            relationship_familiarity: "friendly",
            recent_openers: [],
            recent_generated_comments: [],
            recent_story_generated_comments: []
          }
        }
      )
    end

    suggestions = described_class.new(
      personalization_engine: engine,
      context_signal_scorer_builder: scorer_builder
    ).generate(
      profile: profile,
      content_understanding: { topics: [], sentiment: "neutral", image_description: "Sunset story" },
      max_suggestions: 5
    )

    expect(suggestions).not_to be_empty
    expect(suggestions.join(" ").downcase).to(match(/travel|beach/))
  end

  it "avoids repeating recent opener signatures from engagement memory" do
    account = InstagramAccount.create!(username: "acct_#{SecureRandom.hex(4)}")
    profile = account.instagram_profiles.create!(username: "profile_#{SecureRandom.hex(4)}")
    engine = instance_double(PersonalizationEngine, build: { tone: "friendly", interests: [ "travel" ] })

    scorer_builder = lambda do |profile:, channel:|
      FakeScorer.new(
        {
          prioritized_signals: [ { value: "travel" } ],
          engagement_memory: {
            relationship_familiarity: "friendly",
            recent_openers: [ "this feels very" ],
            recent_generated_comments: [ "This feels very you lately, especially around travel." ],
            recent_story_generated_comments: []
          }
        }
      )
    end

    suggestions = described_class.new(
      personalization_engine: engine,
      context_signal_scorer_builder: scorer_builder
    ).generate(
      profile: profile,
      content_understanding: { topics: [ "travel" ], sentiment: "neutral" },
      max_suggestions: 5
    )

    expect(suggestions).not_to include("This feels very you lately, especially around travel.")
    expect(suggestions.length).to be >= 1
  end
end
