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
      verified_story_facts: { ocr_text: "Morning run", transcript: "Morning run by the beach" }
    )

    expect(result).to be_an(Array)
    expect(result.first).to include(:comment, :score, :factors, :auto_post_eligible, :confidence_level)
    expect(result.first[:score]).to be_between(0.0, 3.0)
    expect(result.first[:factors]).to include(:visual_context, :ocr_text, :transcript, :user_context_match, :engagement_relevance)
  end

  it "annotates LLM ordering with a lightweight selection bonus" do
    result = described_class.annotate_llm_order_with_breakdown(
      suggestions: [
        "Great run by the beach.",
        "Nice post."
      ],
      image_description: "Morning run by the beach with sunrise tones",
      topics: [ "fitness", "morning", "run" ],
      historical_comments: [],
      scored_context: {},
      verified_story_facts: {}
    )

    expect(result.first).to include(:comment, :score, :relevance_score, :llm_rank, :llm_order_bonus, :factors)
    expect(result.first[:llm_rank]).to eq(1)
    expect(result.first[:score]).to be >= result.first[:relevance_score]
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

  it "prefers high-confidence anchors over low-confidence object pair phrasing" do
    ranked = described_class.rank_with_breakdown(
      suggestions: [
        "Person and sink, an intriguing duo. 🧐",
        "Nice bottle setup! 🥂"
      ],
      image_description: "Visual elements: bottle, person, sink. Inferred topics: bottle, person, sink.",
      topics: %w[bottle person sink],
      historical_comments: [],
      scored_context: { engagement_memory: { relationship_familiarity: "new" } },
      verified_story_facts: {
        objects: %w[bottle person sink],
        object_detections: [
          { label: "bottle", confidence: 0.834 },
          { label: "person", confidence: 0.826 },
          { label: "sink", confidence: 0.41 }
        ]
      }
    )

    expect(ranked.first[:comment]).to eq("Nice bottle setup! 🥂")
  end

  it "penalizes generic compliments when specific visual anchors exist" do
    ranked = described_class.rank_with_breakdown(
      suggestions: [
        "Person looks great here.",
        "Great timing on this cricket shot."
      ],
      image_description: "Cricket action shot in a stadium with crowd energy",
      topics: %w[cricket stadium match],
      historical_comments: [],
      scored_context: { engagement_memory: { relationship_familiarity: "new" } },
      verified_story_facts: {
        objects: %w[player bat stadium crowd],
        ocr_text: ""
      }
    )

    expect(ranked.first[:comment]).to eq("Great timing on this cricket shot.")
  end

  it "prefers text-grounded comments for text-heavy story frames" do
    ranked = described_class.rank_with_breakdown(
      suggestions: [
        "This moment looks great here.",
        "The loan offer text is clear and attention-grabbing."
      ],
      image_description: "Bank poster with loan offer and rate details",
      topics: %w[loan bank offer],
      historical_comments: [],
      scored_context: { engagement_memory: { relationship_familiarity: "new" } },
      verified_story_facts: {
        ocr_text: "Smart Personal Loan Starting 10.99%",
        objects: %w[poster text]
      }
    )

    expect(ranked.first[:comment]).to eq("The loan offer text is clear and attention-grabbing.")
  end
end
