require "rails_helper"
require "securerandom"

RSpec.describe "InstagramProfiles mutual friends", type: :request do
  it "renders profile-specific mutual friends from API instead of account-wide mutuals" do
    account = InstagramAccount.create!(username: "acct_#{SecureRandom.hex(4)}")
    profile = InstagramProfile.create!(instagram_account: account, username: "target_#{SecureRandom.hex(3)}")
    unrelated = InstagramProfile.create!(
      instagram_account: account,
      username: "unrelated_#{SecureRandom.hex(3)}",
      following: true,
      follows_you: true
    )
    expected_mutual = InstagramProfile.create!(
      instagram_account: account,
      username: "expected_#{SecureRandom.hex(3)}",
      following: false,
      follows_you: false
    )

    client = instance_double(Instagram::Client)
    allow(Instagram::Client).to receive(:new).and_return(client)
    allow(client).to receive(:fetch_mutual_friends).and_return(
      [
        {
          username: expected_mutual.username,
          display_name: expected_mutual.username,
          profile_pic_url: nil
        }
      ]
    )

    post select_instagram_account_path(account)
    assert_response :redirect

    get instagram_profile_path(profile)

    assert_response :success
    expect(response.body).to include("@#{expected_mutual.username}")
    expect(response.body).not_to include("@#{unrelated.username}")
    expect(Instagram::Client).to have_received(:new).with(account: account)
    expect(client).to have_received(:fetch_mutual_friends).with(profile_username: profile.username, limit: 36)
  end
end
