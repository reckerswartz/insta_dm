require "rails_helper"
require "securerandom"

RSpec.describe "InstagramProfiles captured post person links", type: :request do
  it "renders person links with top-level turbo navigation from captured posts frame" do
    account = InstagramAccount.create!(username: "acct_#{SecureRandom.hex(4)}")
    profile = InstagramProfile.create!(instagram_account: account, username: "profile_#{SecureRandom.hex(4)}")
    post = InstagramProfilePost.create!(
      instagram_account: account,
      instagram_profile: profile,
      shortcode: "post_#{SecureRandom.hex(3)}",
      taken_at: Time.current,
      metadata: {}
    )
    person = InstagramStoryPerson.create!(
      instagram_account: account,
      instagram_profile: profile,
      role: "secondary_person",
      appearance_count: 1,
      first_seen_at: Time.current,
      last_seen_at: Time.current,
      metadata: {}
    )
    post.instagram_post_faces.create!(
      instagram_story_person: person,
      role: "secondary_person",
      detector_confidence: 0.93,
      bounding_box: { "x1" => 1, "y1" => 1, "x2" => 10, "y2" => 12 },
      metadata: {}
    )

    post select_instagram_account_path(account)
    assert_response :redirect

    get captured_posts_section_instagram_profile_path(profile)

    assert_response :success
    expected_href = instagram_profile_instagram_story_person_path(profile, person)
    expect(response.body).to include("href=\"#{expected_href}\"")
    expect(response.body).to include("data-turbo-frame=\"_top\"")
  end
end
