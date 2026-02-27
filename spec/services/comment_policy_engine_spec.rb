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
      context_keywords: %w[lighting mood sunset skyline],
      max_suggestions: 8
    )

    expect(result[:accepted]).to include("Great lighting and strong mood here")
    expect(result[:accepted]).not_to include("You are young and glowing today")
    expect(result[:accepted]).not_to include("This post is porn level")
    expect(result[:accepted]).not_to include("Love this frame, super clean shot")
    expect(result[:rejected]).not_to be_empty
  end

  it "rejects comments with weak visual grounding when context keywords exist" do
    engine = described_class.new

    result = engine.evaluate(
      suggestions: [
        "Amazing content, keep it up!",
        "Skyline colors look beautiful tonight"
      ],
      context_keywords: %w[skyline city lights],
      max_suggestions: 8
    )

    expect(result[:accepted]).to include("Skyline colors look beautiful tonight")
    expect(result[:accepted]).not_to include("Amazing content, keep it up!")
  end

  it "rejects repeated openings from history and near-duplicates in the same batch" do
    engine = described_class.new
    result = engine.evaluate(
      suggestions: [
        "Love this travel moment with the sunset.",
        "Love this travel scene by the sunset glow.",
        "Those sunset colors over the city look unreal."
      ],
      historical_comments: [ "Love this travel moment from yesterday." ],
      context_keywords: %w[travel sunset city],
      max_suggestions: 8
    )

    expect(result[:accepted]).to include("Those sunset colors over the city look unreal.")
    expect(result[:accepted]).not_to include("Love this travel moment with the sunset.")
  end

  it "rejects low-information comments even when generic context tokens appear" do
    engine = described_class.new
    result = engine.evaluate(
      suggestions: [
        "Love this vibe!",
        "The potted plant by the window looks great."
      ],
      context_keywords: %w[detected visual signals story media context potted plant window],
      max_suggestions: 8
    )

    expect(result[:accepted]).to include("The potted plant by the window looks great.")
    expect(result[:accepted]).not_to include("Love this vibe!")
  end

  it "rejects robotic meta phrasing and awkward duo templates" do
    engine = described_class.new
    result = engine.evaluate(
      suggestions: [
        "(Light Question) What's in the bottle? 🔍",
        "Person and sink, an intriguing duo. 🧐",
        "Nice bottle setup! 🥂"
      ],
      context_keywords: %w[bottle person sink],
      max_suggestions: 8
    )

    expect(result[:accepted]).to include("Nice bottle setup! 🥂")
    expect(result[:accepted]).not_to include("(Light Question) What's in the bottle? 🔍")
    expect(result[:accepted]).not_to include("Person and sink, an intriguing duo. 🧐")
  end

  it "rejects third-person perspective for story comments when direct address is required" do
    engine = described_class.new
    result = engine.evaluate(
      suggestions: [
        "That person looks cool.",
        "You look cool in this outfit.",
        "Everyone looks great here.",
        "The vibe across everyone feels real."
      ],
      context_keywords: %w[outfit style],
      max_suggestions: 8,
      channel: "story",
      require_direct_address: true
    )

    expect(result[:accepted]).to include("You look cool in this outfit.")
    expect(result[:accepted]).not_to include("That person looks cool.")
    expect(result[:accepted]).not_to include("Everyone looks great here.")
    expect(result[:accepted]).not_to include("The vibe across everyone feels real.")
    expect(Array(result[:rejected]).any? { |row| Array(row[:reasons]).include?("third_person_perspective") }).to eq(true)
  end
end
