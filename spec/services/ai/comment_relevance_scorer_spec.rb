require "rails_helper"

RSpec.describe Ai::CommentRelevanceScorer do
  it "returns explainable ranked candidates with 0..3 score scale" do
    result = described_class.rank_with_breakdown(
      suggestions: [
        "Love this morning run energy.",
        "Nice post."
      ],
      image_description: "Morning run by the beach with sunrise tones",
      topics: [ "fitness", "morning", "run" ],
      historical_comments: [ "Love this vibe." ],
      scored_context: {
        prioritized_signals: [ { value: "fitness lifestyle", score: 1.8 } ],
        engagement_memory: { relationship_familiarity: "familiar" }
      },
      verified_story_facts: { ocr_text: "Morning run" }
    )

    expect(result).to be_an(Array)
    expect(result.first).to include(:comment, :score, :factors, :auto_post_eligible, :confidence_level)
    expect(result.first[:score]).to be_between(0.0, 3.0)
    expect(result.first[:factors]).to include(:visual_context, :ocr_text, :user_context_match, :engagement_relevance)
  end

  it "keeps sparse context comments reviewable but not auto-post eligible" do
    result = described_class.score_with_breakdown(
      comment: "Nice shot.",
      image_description: "",
      topics: [],
      historical_comments: [],
      scored_context: { engagement_memory: { relationship_familiarity: "new" } },
      verified_story_facts: {}
    )

    expect(result[:score]).to be >= 0.5
    expect(result[:auto_post_eligible]).to eq(false)
    expect(%w[low medium high]).to include(result[:confidence_level])
  end
end
