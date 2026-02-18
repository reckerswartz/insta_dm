require "test_helper"
require "securerandom"

class InstagramProfileEventLocalStoryIntelligenceTest < ActiveSupport::TestCase
  test "persist_local_story_intelligence stores structured metadata" do
    account = InstagramAccount.create!(username: "acct_#{SecureRandom.hex(4)}")
    profile = InstagramProfile.create!(instagram_account: account, username: "profile_#{SecureRandom.hex(4)}")
    event = InstagramProfileEvent.create!(
      instagram_profile: profile,
      kind: "story_downloaded",
      external_id: "event_#{SecureRandom.hex(4)}",
      detected_at: Time.current,
      metadata: {}
    )

    payload = {
      source: "live_local_vision_ocr",
      ocr_text: "Flash sale #deal @mike",
      transcript: "Limited time offer",
      objects: [ "shoe", "person" ],
      hashtags: [ "#deal" ],
      mentions: [ "@mike" ],
      topics: [ "sale", "fashion" ],
      face_count: 2,
      people: [ { person_id: 123, role: "secondary_person" } ]
    }

    event.send(:persist_local_story_intelligence!, payload)

    event.reload
    stored = event.metadata["local_story_intelligence"]

    assert_equal "live_local_vision_ocr", stored["source"]
    assert_equal "Flash sale #deal @mike", stored["ocr_text"]
    assert_equal [ "shoe", "person" ], stored["objects"]
    assert_equal [ "#deal" ], event.metadata["hashtags"]
    assert_equal [ "@mike" ], event.metadata["mentions"]
    assert_equal 2, event.metadata["face_count"]
    assert_equal [ { "person_id" => 123, "role" => "secondary_person" } ], event.metadata["face_people"]
  end

  test "local_story_intelligence_blank is false when face context exists" do
    account = InstagramAccount.create!(username: "acct_#{SecureRandom.hex(4)}")
    profile = InstagramProfile.create!(instagram_account: account, username: "profile_#{SecureRandom.hex(4)}")
    event = InstagramProfileEvent.create!(
      instagram_profile: profile,
      kind: "story_downloaded",
      external_id: "event_#{SecureRandom.hex(4)}",
      detected_at: Time.current,
      metadata: {}
    )

    payload = {
      ocr_text: nil,
      transcript: nil,
      objects: [],
      hashtags: [],
      mentions: [],
      topics: [],
      face_count: 1,
      people: []
    }

    assert_equal false, event.send(:local_story_intelligence_blank?, payload)
  end

  test "local_story_intelligence_blank is false when scene context exists" do
    account = InstagramAccount.create!(username: "acct_#{SecureRandom.hex(4)}")
    profile = InstagramProfile.create!(instagram_account: account, username: "profile_#{SecureRandom.hex(4)}")
    event = InstagramProfileEvent.create!(
      instagram_profile: profile,
      kind: "story_downloaded",
      external_id: "event_#{SecureRandom.hex(4)}",
      detected_at: Time.current,
      metadata: {}
    )

    payload = {
      ocr_text: nil,
      transcript: nil,
      objects: [],
      object_detections: [],
      ocr_blocks: [],
      scenes: [ { "type" => "scene_change", "timestamp" => 1.2 } ],
      hashtags: [],
      mentions: [],
      topics: [],
      face_count: 0,
      people: []
    }

    assert_equal false, event.send(:local_story_intelligence_blank?, payload)
  end

  test "local_story_intelligence_payload derives objects from object detections" do
    account = InstagramAccount.create!(username: "acct_#{SecureRandom.hex(4)}")
    profile = InstagramProfile.create!(instagram_account: account, username: "profile_#{SecureRandom.hex(4)}")
    event = InstagramProfileEvent.create!(
      instagram_profile: profile,
      kind: "story_downloaded",
      external_id: "event_#{SecureRandom.hex(4)}",
      detected_at: Time.current,
      metadata: {
        "object_detections" => [
          { "label" => "Coffee Cup", "confidence" => 0.91 },
          { "description" => "Desk", "score" => 0.76 }
        ],
        "local_story_intelligence" => {
          "source" => "event_local_pipeline",
          "object_detections" => [
            { "label" => "Coffee Cup", "confidence" => 0.91 },
            { "label" => "Laptop", "confidence" => 0.88 }
          ]
        }
      }
    )

    payload = event.send(:local_story_intelligence_payload)

    assert_includes payload[:objects], "Coffee Cup"
    assert_includes payload[:objects], "Laptop"
    assert_includes payload[:topics], "Coffee Cup"
    assert_includes payload[:topics], "Laptop"
  end

  test "story_excluded_from_narrative detects third-party classifications" do
    account = InstagramAccount.create!(username: "acct_#{SecureRandom.hex(4)}")
    profile = InstagramProfile.create!(instagram_account: account, username: "profile_#{SecureRandom.hex(4)}")
    event = InstagramProfileEvent.create!(
      instagram_profile: profile,
      kind: "story_downloaded",
      external_id: "event_#{SecureRandom.hex(4)}",
      detected_at: Time.current,
      metadata: {}
    )

    excluded = event.send(
      :story_excluded_from_narrative?,
      ownership: { label: "third_party_content" },
      policy: { allow_comment: false, reason_code: "third_party_content" }
    )

    assert_equal true, excluded
  end
end
