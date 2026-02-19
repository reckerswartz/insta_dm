require "rails_helper"
require "base64"
require "securerandom"
require "stringio"

RSpec.describe "PostFaceRecognitionServiceTest" do
  PNG_1PX_BASE64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO6k8fQAAAAASUVORK5CYII=".freeze
  it "process stores matched faces for image posts" do
    account = InstagramAccount.create!(username: "acct_#{SecureRandom.hex(4)}")
    profile = InstagramProfile.create!(instagram_account: account, username: "profile_#{SecureRandom.hex(4)}")
    person = InstagramStoryPerson.create!(
      instagram_account: account,
      instagram_profile: profile,
      role: "secondary_person",
      appearance_count: 1,
      first_seen_at: Time.current,
      last_seen_at: Time.current,
      canonical_embedding: [ 0.1, 0.2, 0.3 ]
    )

    post = InstagramProfilePost.create!(
      instagram_account: account,
      instagram_profile: profile,
      shortcode: "post_#{SecureRandom.hex(3)}",
      taken_at: Time.current
    )
    post.media.attach(
      io: StringIO.new(Base64.decode64(PNG_1PX_BASE64)),
      filename: "tiny.png",
      content_type: "image/png"
    )

    fake_detection = Class.new do
      def detect(media_payload:)
        {
          faces: [ { confidence: 0.91, bounding_box: { "x1" => 1, "y1" => 2, "x2" => 10, "y2" => 12 }, landmarks: [], likelihoods: {} } ],
          ocr_text: "hello #tag @friend",
          content_signals: [ "person" ],
          hashtags: [ "#tag" ],
          mentions: [ "@friend" ]
        }
      end
    end.new

    fake_embedding = Class.new do
      def embed(media_payload:, face:)
        { vector: [ 0.11, 0.22, 0.33 ], version: "test_v1" }
      end
    end.new

    fake_matcher = Class.new do
      def initialize(person)
        @person = person
      end

      def match_or_create!(account:, profile:, embedding:, occurred_at:, observation_signature: nil)
        { person: @person, role: "secondary_person", similarity: 0.97 }
      end
    end.new(person)

    fake_identity_resolver = Class.new do
      attr_reader :calls

      def initialize
        @calls = []
      end

      def resolve_for_post!(post:, extracted_usernames:, content_summary:)
        @calls << {
          post_id: post.id,
          extracted_usernames: extracted_usernames,
          content_summary: content_summary
        }
        {
          skipped: false,
          summary: {
            participants: [ { person_id: 123, role: "secondary_person" } ],
            participant_summary_text: "Participants: person_123"
          }
        }
      end
    end.new

    service = PostFaceRecognitionService.new(
      face_detection_service: fake_detection,
      face_embedding_service: fake_embedding,
      vector_matching_service: fake_matcher,
      face_identity_resolution_service: fake_identity_resolver
    )

    result = service.process!(post: post)
    post.reload

    assert_equal false, result[:skipped]
    assert_equal 1, post.instagram_post_faces.count
    assert_equal 1, post.metadata.dig("face_recognition", "face_count")
    assert_equal "secondary_person", post.instagram_post_faces.first.role
    assert_equal person.id, post.instagram_post_faces.first.instagram_story_person_id
    assert_equal "post_media_image", post.metadata.dig("face_recognition", "detection_source")
    assert_equal "Participants: person_123", post.metadata.dig("face_recognition", "participant_summary")
    assert_equal 1, fake_identity_resolver.calls.length
  end

  it "processes video posts using preview image when available" do
    account = InstagramAccount.create!(username: "acct_#{SecureRandom.hex(4)}")
    profile = InstagramProfile.create!(instagram_account: account, username: "profile_#{SecureRandom.hex(4)}")
    person = InstagramStoryPerson.create!(
      instagram_account: account,
      instagram_profile: profile,
      role: "secondary_person",
      appearance_count: 1,
      first_seen_at: Time.current,
      last_seen_at: Time.current,
      canonical_embedding: [ 0.2, 0.3, 0.4 ]
    )

    post = InstagramProfilePost.create!(
      instagram_account: account,
      instagram_profile: profile,
      shortcode: "post_#{SecureRandom.hex(3)}",
      taken_at: Time.current
    )
    post.media.attach(
      io: StringIO.new("video-binary"),
      filename: "sample.mp4",
      content_type: "video/mp4"
    )
    post.preview_image.attach(
      io: StringIO.new(Base64.decode64(PNG_1PX_BASE64)),
      filename: "preview.png",
      content_type: "image/png"
    )

    fake_detection = Class.new do
      def detect(media_payload:)
        {
          faces: [ { confidence: 0.88, bounding_box: { "x1" => 2, "y1" => 2, "x2" => 9, "y2" => 9 }, landmarks: [], likelihoods: {} } ],
          ocr_text: "",
          content_signals: [ "person" ],
          hashtags: [],
          mentions: []
        }
      end
    end.new

    fake_embedding = Class.new do
      def embed(media_payload:, face:)
        { vector: [ 0.31, 0.22, 0.13 ], version: "test_v2" }
      end
    end.new

    fake_matcher = Class.new do
      def initialize(person)
        @person = person
      end

      def match_or_create!(account:, profile:, embedding:, occurred_at:, observation_signature: nil)
        { person: @person, role: "secondary_person", similarity: 0.95 }
      end
    end.new(person)

    fake_identity_resolver = Class.new do
      def resolve_for_post!(post:, extracted_usernames:, content_summary:)
        { skipped: false, summary: { participants: [], participant_summary_text: "No identifiable participants found." } }
      end
    end.new

    service = PostFaceRecognitionService.new(
      face_detection_service: fake_detection,
      face_embedding_service: fake_embedding,
      vector_matching_service: fake_matcher,
      face_identity_resolution_service: fake_identity_resolver
    )

    result = service.process!(post: post)
    post.reload

    assert_equal false, result[:skipped]
    assert_equal 1, post.instagram_post_faces.count
    assert_equal "post_preview_image", post.metadata.dig("face_recognition", "detection_source")
  end

  it "preserves existing face links when detection fails transiently" do
    account = InstagramAccount.create!(username: "acct_#{SecureRandom.hex(4)}")
    profile = InstagramProfile.create!(instagram_account: account, username: "profile_#{SecureRandom.hex(4)}")
    person = InstagramStoryPerson.create!(
      instagram_account: account,
      instagram_profile: profile,
      role: "secondary_person",
      appearance_count: 2,
      first_seen_at: Time.current,
      last_seen_at: Time.current,
      canonical_embedding: [ 0.2, 0.1, 0.4 ]
    )

    post = InstagramProfilePost.create!(
      instagram_account: account,
      instagram_profile: profile,
      shortcode: "post_#{SecureRandom.hex(3)}",
      taken_at: Time.current
    )
    post.media.attach(
      io: StringIO.new(Base64.decode64(PNG_1PX_BASE64)),
      filename: "tiny.png",
      content_type: "image/png"
    )
    post.instagram_post_faces.create!(
      instagram_story_person: person,
      role: "secondary_person",
      detector_confidence: 0.8,
      embedding_version: "test",
      embedding: [ 0.2, 0.1, 0.4 ],
      bounding_box: { "x1" => 1, "y1" => 1, "x2" => 2, "y2" => 2 },
      metadata: {}
    )

    failing_detection = Class.new do
      def detect(media_payload:)
        {
          faces: [],
          metadata: {
            reason: "vision_error",
            error_message: "upstream timeout"
          }
        }
      end
    end.new

    service = PostFaceRecognitionService.new(face_detection_service: failing_detection)
    result = service.process!(post: post)
    post.reload

    assert_equal true, result[:skipped]
    assert_equal "face_detection_failed", result[:reason]
    assert_equal 1, post.instagram_post_faces.count
    assert_equal "vision_error", post.metadata.dig("face_recognition", "detection_reason")
    assert_equal "upstream timeout", post.metadata.dig("face_recognition", "detection_error")
  end
end
