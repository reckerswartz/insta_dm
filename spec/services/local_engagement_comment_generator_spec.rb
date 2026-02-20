require "rails_helper"

RSpec.describe Ai::LocalEngagementCommentGenerator do
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
end
