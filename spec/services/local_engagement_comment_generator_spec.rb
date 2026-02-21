require "rails_helper"

RSpec.describe Ai::LocalEngagementCommentGenerator do
  let(:expected_fixture) do
    JSON.parse(File.read(Rails.root.join("spec/fixtures/ai/expected_story_comment_result.json")))
  end

  it "prompt includes compact verified context and excludes low-value raw fields" do
    fake_client = Class.new do
      def generate(model:, prompt:, temperature:, max_tokens:)
        {
          "response" => "{\"comment_suggestions\":[\"Nice post\"]}"
        }
      end
    end.new

    generator = Ai::LocalEngagementCommentGenerator.new(ollama_client: fake_client, model: "mistral:7b")

    prompt = generator.send(
      :build_prompt,
      post_payload: { post: { id: 1 }, author_profile: { username: "abc" }, rules: { require_local_pipeline: true } },
      image_description: "Detected visual signals: person",
      topics: %w[fitness morning],
      author_type: "personal",
      channel: "story",
      historical_comments: [ "Love this vibe" ],
      historical_context: "Recent structured story intelligence...",
      historical_story_context: [ { objects: [ "person" ] } ],
      local_story_intelligence: {
        source: "raw_context",
        ocr_text: "fallback raw text"
      },
      historical_comparison: {
        shared_topics: [ "fitness" ],
        novel_topics: [ "morning" ],
        has_historical_overlap: true
      },
      cv_ocr_evidence: {
        object_detections: [ { label: "person", confidence: 0.9 } ],
        ocr_blocks: [ { text: "work hard", confidence: 0.95 } ]
      },
      verified_story_facts: {
        source: "validated",
        signal_score: 5,
        ocr_text: "work hard",
        objects: [ "person", "clock" ],
        detected_usernames: [ "coach" ],
        hashtags: [ "#grind" ],
        mentions: [ "@coach" ],
        face_count: 1,
        identity_verification: {
          owner_likelihood: "high",
          confidence: 0.78
        }
      },
      story_ownership_classification: {
        label: "owned_by_profile",
        decision: "allow_comment",
        confidence: 0.81
      },
      generation_policy: {
        allow_comment: true,
        reason_code: "verified_context_available"
      },
      scored_context: {
        prioritized_signals: [
          { value: "fitness", signal_type: "topics", score: 2.1, source: "store" }
        ],
        context_keywords: [ "fitness", "morning" ]
      }
    )

    assert_includes prompt, "\"verified_story_facts\""
    assert_includes prompt, "\"ownership\""
    assert_includes prompt, "\"generation_policy\""
    assert_includes prompt, "\"channel\": \"story\""
    assert_includes prompt, "\"tone_plan\""
    assert_includes prompt, "\"occasion_context\""
    assert_includes prompt, "\"visual_anchors\""
    assert_includes prompt, "\"comparison\""
    assert_includes prompt, "\"detected_usernames\""
    assert_includes prompt, "\"identity_verification\""
    assert_includes prompt, "\"scored_context\""
    assert_includes prompt, "\"prioritized_signals\""
    refute_includes prompt, "\"local_story_intelligence\""
    refute_includes prompt, "\"media_url\""
    refute_includes prompt, "\"historical_context_summary\""
    refute_includes prompt, "\"rules\""
  end

  it "diversifies suggestions and adds a light question when missing" do
    fake_client = Class.new do
      def generate(model:, prompt:, temperature:, max_tokens:)
        { "response" => "{\"comment_suggestions\":[]}" }
      end
    end.new

    generator = Ai::LocalEngagementCommentGenerator.new(ollama_client: fake_client, model: "mistral:7b")

    out = generator.send(
      :diversify_suggestions,
      suggestions: [
        "Love this city scene and lighting.",
        "Love this city scene and lighting right now.",
        "Great framing on the skyline tonight."
      ],
      topics: %w[city skyline],
      image_description: "City skyline at sunset",
      channel: "post",
      scored_context: {
        engagement_memory: {
          recent_openers: [ "love this city" ]
        }
      }
    )

    expect(out.length).to be >= 2
    expect(out.any? { |text| text.include?("?") }).to eq(true)
    expect(out.first.downcase).not_to start_with("love this city")
  end

  it "returns anchored fallback suggestions when generation output is empty" do
    fake_client = Class.new do
      def generate(model:, prompt:, temperature:, max_tokens:)
        { "response" => "{\"comment_suggestions\":[]}" }
      end
    end.new

    generator = Ai::LocalEngagementCommentGenerator.new(ollama_client: fake_client, model: "mistral:7b")
    result = generator.generate!(
      post_payload: {},
      image_description: "Visual elements: potted plant, window light.",
      topics: ["plant"],
      author_type: "personal",
      channel: "story",
      verified_story_facts: { objects: ["potted plant"] },
      scored_context: {}
    )

    expect(result[:source]).to eq("fallback")
    expect(result[:comment_suggestions].first.downcase).to include("plant")
    expect(result[:comment_suggestions].none? { |row| row.include?("story media moment") }).to eq(true)
  end

  it "matches fixture-backed quality and structure rules for story suggestions" do
    fake_client = Class.new do
      def generate(model:, prompt:, temperature:, max_tokens:)
        {
          "response" => {
            comment_suggestions: [
              "Love the plant corner and the soft window light.",
              "That green setup looks so calming. Where is this from?"
            ]
          }.to_json
        }
      end
    end.new

    generator = Ai::LocalEngagementCommentGenerator.new(ollama_client: fake_client, model: "mistral:7b")
    result = generator.generate!(
      post_payload: {},
      image_description: "Visual elements: potted plant, window light.",
      topics: ["plant", "home"],
      author_type: "personal",
      channel: "story",
      verified_story_facts: { objects: ["potted plant"], topics: ["plant"] },
      scored_context: {}
    )

    required_keys = Array(expected_fixture["required_keys"]).map(&:to_s)
    rules = expected_fixture["quality_rules"].is_a?(Hash) ? expected_fixture["quality_rules"] : {}
    min_suggestions = rules["min_suggestions"].to_i
    max_comment_length = rules["max_comment_length"].to_i
    anchored = ActiveModel::Type::Boolean.new.cast(rules["must_include_topic_anchor"])
    no_empty = ActiveModel::Type::Boolean.new.cast(rules["disallow_empty_or_whitespace"])

    required_keys.each do |key|
      expect(result.key?(key.to_sym) || result.key?(key)).to eq(true), "Missing expected key: #{key}"
    end

    suggestions = Array(result[:comment_suggestions]).map(&:to_s)
    expect(suggestions.length).to be >= min_suggestions
    expect(suggestions.all? { |row| row.length <= max_comment_length }).to eq(true)
    expect(suggestions.any? { |row| row.downcase.include?("plant") || row.downcase.include?("green") }).to eq(true) if anchored
    expect(suggestions.any? { |row| row.strip.empty? }).to eq(false) if no_empty
  end
end
