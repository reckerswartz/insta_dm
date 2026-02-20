require "rails_helper"

RSpec.describe Ai::CommentPolicyEngine do
  it "filters sensitive and repetitive suggestions" do
    engine = described_class.new

    result = engine.evaluate(
      suggestions: [
        "You are young and glowing today",
        "Love this frame, super clean shot",
        "Love this frame, super clean shot",
        "This post is porn level",
        "Great lighting and strong mood here"
      ],
      historical_comments: [ "Love this frame, super clean shot" ],
      max_suggestions: 8
    )

    expect(result[:accepted]).to include("Great lighting and strong mood here")
    expect(result[:accepted]).not_to include("You are young and glowing today")
    expect(result[:accepted]).not_to include("This post is porn level")
    expect(result[:accepted]).not_to include("Love this frame, super clean shot")
    expect(result[:rejected]).not_to be_empty
  end
end
