require "rails_helper"
require "securerandom"

RSpec.describe "PersonIdentityFeedbackServiceTest" do
  def build_account_profile
    account = InstagramAccount.create!(username: "acct_#{SecureRandom.hex(4)}")
    profile = InstagramProfile.create!(
      instagram_account: account,
      username: "profile_#{SecureRandom.hex(4)}"
    )
    [ account, profile ]
  end

  def build_post(account:, profile:)
    InstagramProfilePost.create!(
      instagram_account: account,
      instagram_profile: profile,
      shortcode: "post_#{SecureRandom.hex(3)}",
      taken_at: Time.current,
      metadata: {}
    )
  end

  def build_story(account:, profile:)
    InstagramStory.create!(
      instagram_account: account,
      instagram_profile: profile,
      story_id: "story_#{SecureRandom.hex(3)}",
      media_type: "image",
      media_url: "https://example.test/story.jpg",
      taken_at: Time.current,
      processed: true,
      processing_status: "processed",
      metadata: {}
    )
  end

  it "merges identities and moves linked faces to the selected target person" do
    account, profile = build_account_profile
    source = InstagramStoryPerson.create!(
      instagram_account: account,
      instagram_profile: profile,
      role: "secondary_person",
      appearance_count: 3,
      first_seen_at: 3.days.ago,
      last_seen_at: 1.day.ago,
      canonical_embedding: [ 0.1, 0.2, 0.3 ],
      metadata: { "linked_usernames" => [ "friend.alpha" ] }
    )
    target = InstagramStoryPerson.create!(
      instagram_account: account,
      instagram_profile: profile,
      role: "secondary_person",
      appearance_count: 4,
      first_seen_at: 4.days.ago,
      last_seen_at: 2.hours.ago,
      canonical_embedding: [ 0.3, 0.2, 0.1 ],
      metadata: { "linked_usernames" => [ "friend.beta" ] }
    )

    post = build_post(account: account, profile: profile)
    story = build_story(account: account, profile: profile)
    post_face = InstagramPostFace.create!(instagram_profile_post: post, instagram_story_person: source, role: "secondary_person")
    story_face = InstagramStoryFace.create!(instagram_story: story, instagram_story_person: source, role: "secondary_person")

    service = PersonIdentityFeedbackService.new
    merged = service.merge_people!(source_person: source, target_person: target)

    source.reload
    target.reload
    post_face.reload
    story_face.reload

    assert_equal target.id, merged.id
    assert_equal target.id, post_face.instagram_story_person_id
    assert_equal target.id, story_face.instagram_story_person_id
    assert_equal target.id, source.merged_into_person_id
    assert_equal "unknown", source.role
    assert_equal 0, source.appearance_count
    assert source.canonical_embedding.blank?
    assert_includes Array(target.metadata["linked_usernames"]), "friend.alpha"
    assert_includes Array(target.metadata["linked_usernames"]), "friend.beta"
    assert target.identity_confidence.positive?
  end

  it "separates one detection into a new persistent person id" do
    account, profile = build_account_profile
    person = InstagramStoryPerson.create!(
      instagram_account: account,
      instagram_profile: profile,
      role: "secondary_person",
      appearance_count: 2,
      first_seen_at: 2.days.ago,
      last_seen_at: Time.current,
      canonical_embedding: [ 0.2, 0.3, 0.4 ],
      metadata: {}
    )
    post = build_post(account: account, profile: profile)
    face = InstagramPostFace.create!(
      instagram_profile_post: post,
      instagram_story_person: person,
      role: "secondary_person",
      embedding: [ 0.21, 0.31, 0.41 ],
      metadata: {}
    )

    service = PersonIdentityFeedbackService.new
    new_person = service.separate_face!(person: person, face: face)

    person.reload
    face.reload
    new_person.reload

    assert new_person.id != person.id
    assert_equal new_person.id, face.instagram_story_person_id
    assert_equal person.id, new_person.metadata["separated_from_person_id"]
    assert_equal "secondary_person", new_person.role
    assert_equal 1, new_person.appearance_count
    assert_equal 0, person.appearance_count
    assert person.identity_confidence <= new_person.identity_confidence
  end

  it "marks a person incorrect and disables future matching signals" do
    account, profile = build_account_profile
    person = InstagramStoryPerson.create!(
      instagram_account: account,
      instagram_profile: profile,
      role: "secondary_person",
      appearance_count: 5,
      first_seen_at: 3.days.ago,
      last_seen_at: Time.current,
      canonical_embedding: [ 0.4, 0.3, 0.2 ],
      metadata: {}
    )
    post = build_post(account: account, profile: profile)
    face = InstagramPostFace.create!(
      instagram_profile_post: post,
      instagram_story_person: person,
      role: "secondary_person",
      metadata: {}
    )

    service = PersonIdentityFeedbackService.new
    service.mark_incorrect!(person: person, reason: "false_positive")

    person.reload
    face.reload

    assert_equal "incorrect", person.real_person_status
    assert_equal true, ActiveModel::Type::Boolean.new.cast(person.metadata["matching_disabled"])
    assert person.canonical_embedding.blank?
    assert_equal "incorrect", face.metadata.dig("user_feedback", "status")
    assert_equal "false_positive", face.metadata.dig("user_feedback", "reason")
    assert_equal false, person.active_for_matching?
  end

  it "confirms person identity and links profile owner mapping" do
    account, profile = build_account_profile
    person = InstagramStoryPerson.create!(
      instagram_account: account,
      instagram_profile: profile,
      role: "secondary_person",
      appearance_count: 2,
      first_seen_at: 1.day.ago,
      last_seen_at: Time.current,
      canonical_embedding: [ 0.5, 0.1, 0.3 ],
      metadata: {}
    )

    service = PersonIdentityFeedbackService.new
    service.confirm_person!(person: person, label: "close_friend")
    service.link_profile_owner!(person: person)
    person.reload

    assert_equal "confirmed_real_person", person.real_person_status
    assert_equal "primary_user", person.role
    assert_equal "close_friend", person.label
    assert_includes Array(person.metadata["linked_usernames"]), profile.username.downcase
    assert person.identity_confidence > 0.5
  end
end
