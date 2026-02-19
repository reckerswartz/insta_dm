require "rails_helper"
require "securerandom"

RSpec.describe "InstagramStoryPeople", type: :request do
  def build_account_profile
    account = InstagramAccount.create!(username: "acct_#{SecureRandom.hex(4)}")
    profile = InstagramProfile.create!(
      instagram_account: account,
      username: "profile_#{SecureRandom.hex(4)}"
    )
    [ account, profile ]
  end

  def select_account(account)
    post select_instagram_account_path(account)
    assert_response :redirect
  end

  it "renders the person profile page with aggregated media sections" do
    account, profile = build_account_profile
    select_account(account)
    person = InstagramStoryPerson.create!(
      instagram_account: profile.instagram_account,
      instagram_profile: profile,
      role: "secondary_person",
      appearance_count: 1,
      first_seen_at: Time.current,
      last_seen_at: Time.current,
      metadata: {}
    )

    get instagram_profile_instagram_story_person_path(profile, person)

    assert_response :success
    expect(response.body).to include("Identity Controls")
    expect(response.body).to include("Captured Posts Featuring This Person")
  end

  it "confirms person identity through feedback endpoints" do
    account, profile = build_account_profile
    select_account(account)
    person = InstagramStoryPerson.create!(
      instagram_account: profile.instagram_account,
      instagram_profile: profile,
      role: "secondary_person",
      appearance_count: 2,
      first_seen_at: Time.current,
      last_seen_at: Time.current,
      metadata: {}
    )

    post confirm_instagram_profile_instagram_story_person_path(profile, person), params: {
      real_person_status: "confirmed_real_person",
      label: "friend_label"
    }

    assert_redirected_to instagram_profile_instagram_story_person_path(profile, person)
    person.reload
    assert_equal "confirmed_real_person", person.real_person_status
    assert_equal "friend_label", person.label
  end

  it "merges one person into another and redirects to the target person page" do
    account, profile = build_account_profile
    select_account(account)
    source = InstagramStoryPerson.create!(
      instagram_account: profile.instagram_account,
      instagram_profile: profile,
      role: "secondary_person",
      appearance_count: 1,
      first_seen_at: Time.current,
      last_seen_at: Time.current,
      canonical_embedding: [ 0.1, 0.2, 0.3 ],
      metadata: {}
    )
    target = InstagramStoryPerson.create!(
      instagram_account: profile.instagram_account,
      instagram_profile: profile,
      role: "secondary_person",
      appearance_count: 1,
      first_seen_at: Time.current,
      last_seen_at: Time.current,
      canonical_embedding: [ 0.3, 0.2, 0.1 ],
      metadata: {}
    )

    post merge_instagram_profile_instagram_story_person_path(profile, source), params: { target_person_id: target.id }

    assert_redirected_to instagram_profile_instagram_story_person_path(profile, target)
    source.reload
    assert_equal target.id, source.merged_into_person_id
  end
end
