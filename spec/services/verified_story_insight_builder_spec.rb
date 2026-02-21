require "rails_helper"

RSpec.describe Ai::VerifiedStoryInsightBuilder do
  ProfileStub = Struct.new(:username)

  it "classifies reshare and blocks generation when external usernames and reshare terms are detected" do
    profile = ProfileStub.new("owner_account")
    payload = {
      ocr_text: "repost via @another_creator #inspo",
      mentions: [ "@another_creator" ],
      hashtags: [ "#inspo" ],
      object_detections: [ { label: "person", confidence: 0.9 } ],
      face_count: 1,
      people: [ { role: "secondary_person", person_id: 123 } ]
    }
    metadata = {
      "story_url" => "https://www.instagram.com/another_creator/"
    }

    result = Ai::VerifiedStoryInsightBuilder.new(
      profile: profile,
      local_story_intelligence: payload,
      metadata: metadata
    ).build

    assert_equal "reshare", result.dig(:ownership_classification, :label)
    assert_equal "skip_comment", result.dig(:ownership_classification, :decision)
    assert_equal false, result.dig(:generation_policy, :allow_comment)
    assert_includes Array(result.dig(:ownership_classification, :reason_codes)), "external_usernames_detected"
    assert_includes Array(result.dig(:ownership_classification, :reason_codes)), "reshare_indicators_detected"
  end

  it "classifies owned profile content and allows generation with strong verified signals" do
    profile = ProfileStub.new("owner_account")
    payload = {
      ocr_text: "Morning run with @owner_account #fitness",
      mentions: [ "@owner_account" ],
      hashtags: [ "#fitness" ],
      object_detections: [ { label: "person", confidence: 0.92 }, { label: "road", confidence: 0.71 } ],
      topics: [ "fitness" ],
      face_count: 1,
      people: [ { role: "primary_user", person_id: 77 } ]
    }

    result = Ai::VerifiedStoryInsightBuilder.new(
      profile: profile,
      local_story_intelligence: payload,
      metadata: {}
    ).build

    assert_equal "owned_by_profile", result.dig(:ownership_classification, :label)
    assert_equal "allow_comment", result.dig(:ownership_classification, :decision)
    assert_equal true, result.dig(:generation_policy, :allow_comment)
    assert_operator result.dig(:verified_story_facts, :signal_score), :>=, 2
    assert_includes %w[high medium], result.dig(:verified_story_facts, :identity_verification, :owner_likelihood)
  end

  it "blocks low-signal content when ownership cannot be verified" do
    profile = ProfileStub.new("owner_account")
    payload = {
      object_detections: [ { label: "person", confidence: 0.9 } ],
      face_count: 0,
      people: []
    }
    metadata = {
      "story_url" => "https://www.instagram.com/stories/owner_account/",
      "media_type" => "image"
    }

    result = Ai::VerifiedStoryInsightBuilder.new(
      profile: profile,
      local_story_intelligence: payload,
      metadata: metadata
    ).build

    assert_equal "insufficient_evidence", result.dig(:ownership_classification, :label)
    assert_equal "skip_comment", result.dig(:ownership_classification, :decision)
    assert_equal true, result.dig(:generation_policy, :allow_comment)
    assert_equal false, result.dig(:generation_policy, :allow_auto_post)
    assert_equal true, result.dig(:generation_policy, :manual_review_required)
    assert_includes Array(result.dig(:ownership_classification, :reason_codes)), "insufficient_verified_signals"
  end

  it "captures source profile references and marks third-party content" do
    profile = ProfileStub.new("owner_account")
    payload = {
      ocr_text: "oxox_ttxtx shared this meme",
      object_detections: [ { label: "person", confidence: 0.92 } ],
      mentions: []
    }
    metadata = {
      "story_ref" => "owner_account:",
      "story_url" => "https://www.instagram.com/stories/owner_account/",
      "permalink" => "https://www.instagram.com/oxox_ttxtx/"
    }

    result = Ai::VerifiedStoryInsightBuilder.new(
      profile: profile,
      local_story_intelligence: payload,
      metadata: metadata
    ).build

    assert_includes Array(result.dig(:verified_story_facts, :source_profile_references)), "owner_account"
    assert_includes Array(result.dig(:verified_story_facts, :source_profile_references)), "oxox_ttxtx"
    assert_includes %w[third_party_content reshare meme_reshare], result.dig(:ownership_classification, :label)
    assert_equal false, result.dig(:generation_policy, :allow_comment)
  end

  it "blocks reshared meme-style content even when profile username is present in source refs" do
    profile = ProfileStub.new("owner_account")
    payload = {
      ocr_text: "Don't worry. Take this oxox_.txtx",
      profile_handles: [ "oxox_.txtx" ],
      object_detections: [ { label: "person", confidence: 0.9 } ]
    }
    metadata = {
      "story_ref" => "owner_account:",
      "story_url" => "https://www.instagram.com/stories/owner_account/"
    }

    result = Ai::VerifiedStoryInsightBuilder.new(
      profile: profile,
      local_story_intelligence: payload,
      metadata: metadata
    ).build

    assert_includes %w[reshare meme_reshare third_party_content], result.dig(:ownership_classification, :label)
    assert_equal "skip_comment", result.dig(:ownership_classification, :decision)
    assert_equal false, result.dig(:generation_policy, :allow_comment)
  end

  it "flags low identity likelihood with external usernames as third-party content" do
    profile = ProfileStub.new("owner_account")
    payload = {
      ocr_text: "@another_creator",
      mentions: [ "@another_creator" ],
      face_count: 1,
      people: [ { role: "secondary_person", person_id: 1001 } ],
      object_detections: [ { label: "person", confidence: 0.91 } ]
    }
    metadata = {
      "story_url" => "https://www.instagram.com/another_creator/"
    }

    result = Ai::VerifiedStoryInsightBuilder.new(
      profile: profile,
      local_story_intelligence: payload,
      metadata: metadata
    ).build

    assert_includes %w[third_party_content reshare], result.dig(:ownership_classification, :label)
    assert_equal false, result.dig(:generation_policy, :allow_comment)
    assert_equal "low", result.dig(:verified_story_facts, :identity_verification, :owner_likelihood)
  end
end
