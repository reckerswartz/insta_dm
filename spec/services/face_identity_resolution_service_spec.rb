require "rails_helper"
require "securerandom"

RSpec.describe "FaceIdentityResolutionServiceTest" do
  def build_account_profile
    account = InstagramAccount.create!(username: "acct_#{SecureRandom.hex(4)}")
    profile = InstagramProfile.create!(
      instagram_account: account,
      username: "profile_#{SecureRandom.hex(4)}",
      display_name: "Profile User",
      bio: "Creator, photographer, fitness coach"
    )
    [ account, profile ]
  end

  def create_post(profile:, account:, shortcode:)
    InstagramProfilePost.create!(
      instagram_account: account,
      instagram_profile: profile,
      shortcode: shortcode,
      taken_at: Time.current,
      metadata: {}
    )
  end

  def create_story(profile:, account:, story_id:)
    InstagramStory.create!(
      instagram_account: account,
      instagram_profile: profile,
      story_id: story_id,
      media_type: "image",
      media_url: "https://example.test/#{story_id}.jpg",
      taken_at: Time.current,
      metadata: {},
      processed: true,
      processing_status: "processed"
    )
  end
  it "promotes dominant recurring person as primary identity across posts and stories" do
    account, profile = build_account_profile

    dominant = InstagramStoryPerson.create!(
      instagram_account: account,
      instagram_profile: profile,
      role: "secondary_person",
      appearance_count: 1,
      first_seen_at: 2.days.ago,
      last_seen_at: 1.day.ago,
      metadata: {}
    )
    secondary = InstagramStoryPerson.create!(
      instagram_account: account,
      instagram_profile: profile,
      role: "secondary_person",
      appearance_count: 1,
      first_seen_at: 2.days.ago,
      last_seen_at: 1.day.ago,
      metadata: {}
    )

    story1 = create_story(profile: profile, account: account, story_id: "story_#{SecureRandom.hex(3)}")
    story2 = create_story(profile: profile, account: account, story_id: "story_#{SecureRandom.hex(3)}")
    post1 = create_post(profile: profile, account: account, shortcode: "post_#{SecureRandom.hex(3)}")

    InstagramStoryFace.create!(instagram_story: story1, instagram_story_person: dominant, role: "secondary_person")
    InstagramStoryFace.create!(instagram_story: story1, instagram_story_person: secondary, role: "secondary_person")
    InstagramStoryFace.create!(instagram_story: story2, instagram_story_person: dominant, role: "secondary_person")
    InstagramPostFace.create!(instagram_profile_post: post1, instagram_story_person: dominant, role: "secondary_person")

    out = FaceIdentityResolutionService.new.resolve_for_post!(
      post: post1,
      extracted_usernames: ["@#{profile.username}"],
      content_summary: { ocr_text: "#{profile.username}" }
    )

    dominant.reload
    secondary.reload
    profile.reload
    post1.reload

    assert_equal false, out[:skipped]
    assert_equal "primary_user", dominant.role
    assert_equal "secondary_person", secondary.role
    assert_equal dominant.id, out.dig(:summary, :primary_identity, :person_id)
    assert_equal true, out.dig(:summary, :primary_identity, :confirmed)
    assert_equal "primary_user", out.dig(:summary, :participants, 0, :role)
    assert_equal true, ActiveModel::Type::Boolean.new.cast(out.dig(:summary, :participants, 0, :owner_match))
    assert_equal true, ActiveModel::Type::Boolean.new.cast(out.dig(:summary, :participants, 0, :recurring_face))
    assert_equal dominant.id, post1.metadata.dig("face_identity", "primary_identity", "person_id")
    assert_equal "primary_user", post1.instagram_post_faces.first.reload.role

    behavior = profile.instagram_profile_behavior_profile
    assert behavior.present?
    assert_equal dominant.id, behavior.behavioral_summary.dig("face_identity_profile", "person_id")
  end
  it "links extracted usernames to detected faces and tracks collaborator relationship" do
    account, profile = build_account_profile

    primary = InstagramStoryPerson.create!(
      instagram_account: account,
      instagram_profile: profile,
      role: "primary_user",
      label: profile.username,
      appearance_count: 4,
      first_seen_at: 3.days.ago,
      last_seen_at: 1.day.ago,
      metadata: { "linked_usernames" => [profile.username] }
    )
    collaborator = InstagramStoryPerson.create!(
      instagram_account: account,
      instagram_profile: profile,
      role: "secondary_person",
      appearance_count: 2,
      first_seen_at: 2.days.ago,
      last_seen_at: 1.day.ago,
      metadata: {}
    )

    story = create_story(profile: profile, account: account, story_id: "story_#{SecureRandom.hex(3)}")
    InstagramStoryFace.create!(instagram_story: story, instagram_story_person: primary, role: "primary_user")
    InstagramStoryFace.create!(instagram_story: story, instagram_story_person: collaborator, role: "secondary_person")

    out = FaceIdentityResolutionService.new.resolve_for_story!(
      story: story,
      extracted_usernames: ["@friend.collab"],
      content_summary: {
        profile_handles: ["friend.collab"],
        ocr_text: "Great day with friend.collab"
      }
    )

    collaborator.reload
    story.reload

    assert_equal false, out[:skipped]
    assert_includes Array(collaborator.metadata["linked_usernames"]), "friend.collab"
    assert_equal "occasional_collaborator", collaborator.metadata["relationship"]

    username_matches = Array(out.dig(:summary, :username_face_matches))
    assert username_matches.any? { |row| row[:username] == "friend.collab" && row[:person_id] == collaborator.id }
    assert_equal "story", story.metadata.dig("face_identity", "source_type")
  end
end
