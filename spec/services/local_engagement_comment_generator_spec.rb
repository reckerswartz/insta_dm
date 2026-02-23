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

    generator = Ai::LocalEngagementCommentGenerator.new(ollama_client: fake_client, model: "llama3.2-vision:11b")

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
    assert_includes prompt, "\"channel\":\"story\""
    assert_includes prompt, "\"tone_plan\""
    assert_includes prompt, "\"voice_directives\""
    assert_includes prompt, "\"emoji_policy\""
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

    generator = Ai::LocalEngagementCommentGenerator.new(ollama_client: fake_client, model: "llama3.2-vision:11b")

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

  it "returns llm telemetry with prompt and token-eval counters" do
    fake_client = Class.new do
      def generate(model:, prompt:, temperature:, max_tokens:)
        {
          "response" => {
            comment_suggestions: [
              "Nice plant frame.",
              "Love the green corner vibe.",
              "Clean setup and soft light.",
              "Great plant detail here.",
              "This looks calm and fresh.",
              "Where did you get this plant setup?",
              "The framing on this is solid.",
              "Nice balance and texture here."
            ]
          }.to_json,
          "prompt_eval_count" => 321,
          "eval_count" => 55,
          "total_duration" => 1_250_000_000,
          "load_duration" => 120_000_000
        }
      end
    end.new

    generator = Ai::LocalEngagementCommentGenerator.new(ollama_client: fake_client, model: "llama3.2-vision:11b")
    result = generator.generate!(
      post_payload: {},
      image_description: "Visual elements: potted plant, window light.",
      topics: ["plant"],
      author_type: "personal",
      channel: "story",
      verified_story_facts: { objects: ["potted plant"] },
      scored_context: {}
    )

    telemetry = result[:llm_telemetry]
    expect(telemetry).to be_a(Hash)
    expect(telemetry).to have_key(:prompt_chars)
    expect(telemetry[:prompt_chars]).to be >= 0
    expect(telemetry[:prompt_eval_count]).to eq(321)
    expect(telemetry[:eval_count]).to eq(55)
    expect(telemetry[:total_duration_ns]).to eq(1_250_000_000)
    expect(telemetry[:load_duration_ns]).to eq(120_000_000)
  end

  it "returns anchored fallback suggestions when generation output is empty" do
    fake_client = Class.new do
      def generate(model:, prompt:, temperature:, max_tokens:)
        { "response" => "{\"comment_suggestions\":[]}" }
      end
    end.new

    generator = Ai::LocalEngagementCommentGenerator.new(ollama_client: fake_client, model: "llama3.2-vision:11b")
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

  it "uses text-focused fallback templates for OCR-heavy stories" do
    fake_client = Class.new do
      def generate(model:, prompt:, temperature:, max_tokens:)
        { "response" => "{\"comment_suggestions\":[]}" }
      end
    end.new

    generator = Ai::LocalEngagementCommentGenerator.new(ollama_client: fake_client, model: "llama3.2-vision:11b")
    result = generator.generate!(
      post_payload: {},
      image_description: "IDFC first money smart personal loan starting 10.99 percent",
      topics: ["loan", "bank"],
      author_type: "personal",
      channel: "story",
      verified_story_facts: { ocr_text: "FIRSTmoney Smart Personal Loan Starting 10.99%", objects: ["poster"] },
      scored_context: {}
    )

    suggestions = Array(result[:comment_suggestions]).map(&:downcase)
    expect(suggestions.any? { |row| row.include?("text") || row.include?("message") || row.include?("layout") }).to eq(true)
    expect(suggestions.any? { |row| row.include?("looks great here") }).to eq(false)
  end

  it "uses group-aware fallback templates when multiple faces are detected" do
    fake_client = Class.new do
      def generate(model:, prompt:, temperature:, max_tokens:)
        { "response" => "{\"comment_suggestions\":[]}" }
      end
    end.new

    generator = Ai::LocalEngagementCommentGenerator.new(ollama_client: fake_client, model: "llama3.2-vision:11b")
    result = generator.generate!(
      post_payload: {},
      image_description: "Family photo near a heritage building.",
      topics: ["person"],
      author_type: "personal",
      channel: "story",
      verified_story_facts: { face_count: 5, objects: ["person", "building"] },
      scored_context: {}
    )

    suggestions = Array(result[:comment_suggestions]).map(&:downcase)
    expect(suggestions.any? { |row| row.include?("group") || row.include?("everyone") }).to eq(true)
  end

  it "prioritizes strong specific detection anchors over weak generic object anchors" do
    fake_client = Class.new do
      def generate(model:, prompt:, temperature:, max_tokens:)
        { "response" => "{\"comment_suggestions\":[]}" }
      end
    end.new

    generator = Ai::LocalEngagementCommentGenerator.new(ollama_client: fake_client, model: "llama3.2-vision:11b")
    anchors = generator.send(
      :build_visual_anchors,
      image_description: "Visual elements: bottle, person, sink.",
      topics: %w[bottle person sink],
      verified_story_facts: {
        object_detections: [
          { label: "bottle", confidence: 0.834 },
          { label: "person", confidence: 0.826 },
          { label: "sink", confidence: 0.41 }
        ],
        objects: %w[bottle person sink]
      },
      scored_context: {}
    )

    expect(anchors.first).to eq("bottle")
    expect(anchors).not_to include("sink")
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

    generator = Ai::LocalEngagementCommentGenerator.new(ollama_client: fake_client, model: "llama3.2-vision:11b")
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

  it "escalates from fast model to quality model when primary pass quality is low" do
    fake_client = Class.new do
      attr_reader :models

      def initialize
        @models = []
      end

      def generate(model:, prompt:, temperature:, max_tokens:)
        @models << model
        if model == "fast-3b"
          {
            "response" => {
              comment_suggestions: [
                "Nice post.",
                "Great vibes.",
                "Looks cool."
              ]
            }.to_json
          }
        else
          {
            "response" => {
              comment_suggestions: [
                "The plant corner and soft light look super calm.",
                "That green setup feels fresh and intentional.",
                "Love how the window light frames the plant details.",
                "This plant styling has such a clean home vibe.",
                "The texture and color balance here look really good.",
                "That pot and light combo works so well together.",
                "Which plant in this setup is your current favorite?",
                "The cozy green theme comes through clearly here."
              ]
            }.to_json
          }
        end
      end
    end.new

    generator = Ai::LocalEngagementCommentGenerator.new(ollama_client: fake_client, model: "fast-3b")
    generator.instance_variable_set(:@enable_model_escalation, true)
    generator.instance_variable_set(:@quality_model, "quality-7b")
    result = generator.generate!(
      post_payload: {},
      image_description: "Visual elements: potted plant, window light.",
      topics: ["plant"],
      author_type: "personal",
      channel: "story",
      verified_story_facts: { objects: ["potted plant"] },
      scored_context: {}
    )

    telemetry = result[:llm_telemetry].is_a?(Hash) ? result[:llm_telemetry] : {}
    routing = telemetry[:routing].is_a?(Hash) ? telemetry[:routing] : {}

    expect(fake_client.models).to include("fast-3b")
    expect(fake_client.models.any? { |row| row != "fast-3b" }).to eq(true)
    expect(result[:model]).not_to eq("fast-3b")
    expect(ActiveModel::Type::Boolean.new.cast(routing[:escalated])).to eq(true)
    expect(Array(routing[:escalation_reasons])).to include("low_accepted_count")
  end
end
