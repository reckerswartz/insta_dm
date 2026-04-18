require "rails_helper"
require "securerandom"

RSpec.describe "Missing-record 404 handling", type: :request do
  def build_account_with_profile
    account = InstagramAccount.create!(username: "acct_#{SecureRandom.hex(4)}")
    profile = InstagramProfile.create!(
      instagram_account: account,
      username: "profile_#{SecureRandom.hex(4)}"
    )
    post select_instagram_account_path(account)
    [ account, profile ]
  end

  describe "GET /instagram_profiles/:id/people/:person_id with missing person" do
    it "returns 404 with the app layout and a breadcrumb back to the owning profile" do
      _, profile = build_account_with_profile

      get instagram_profile_instagram_story_person_path(profile, 9_999_999)

      expect(response).to have_http_status(:not_found)
      expect(response.body).to include("InstaManager")
      expect(response.body).to include("couldn").and include("find that record")
      expect(response.body).to include(instagram_profile_path(profile))
    end
  end

  describe "GET /instagram_posts/:id with missing post" do
    it "returns 404 with the app layout" do
      build_account_with_profile

      get instagram_post_path(9_999_999)

      expect(response).to have_http_status(:not_found)
      expect(response.body).to include("InstaManager")
      expect(response.body).to include("couldn").and include("find that record")
    end
  end
end
