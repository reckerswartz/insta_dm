require "rails_helper"
require "securerandom"

RSpec.describe "API Response Validation Diagnostics", :diagnostic, type: :request do
  it "returns valid tabulator payloads for profile and post JSON endpoints" do
    account = InstagramAccount.create!(username: "api_diag_#{SecureRandom.hex(4)}")
    profile = account.instagram_profiles.create!(
      username: "api_profile_#{SecureRandom.hex(4)}",
      display_name: "API Profile",
      following: true,
      follows_you: true,
      can_message: true,
    )
    account.instagram_posts.create!(
      instagram_profile: profile,
      shortcode: "api_post_#{SecureRandom.hex(4)}",
      detected_at: Time.current,
      status: "analyzed",
      author_username: profile.username,
      post_kind: "post",
    )

    post select_instagram_account_path(account)
    expect(response).to have_http_status(:see_other)

    get "/instagram_profiles.json", params: {
      page: 1,
      size: 25,
      sort: [{ field: "username", dir: "asc" }].to_json,
      filter: [].to_json,
    }
    expect(response).to have_http_status(:ok)
    profiles_payload = JSON.parse(response.body)
    expect(profiles_payload).to include("data", "last_page", "last_row")
    matching_profile = profiles_payload.fetch("data").find do |row|
      row["id"] == profile.id && row["username"] == profile.username
    end
    expect(matching_profile).to be_present

    get "/instagram_posts.json", params: {
      page: 1,
      size: 25,
      sort: [{ field: "detected_at", dir: "desc" }].to_json,
      filter: [].to_json,
    }
    expect(response).to have_http_status(:ok)
    posts_payload = JSON.parse(response.body)
    expect(posts_payload).to include("data", "last_page", "last_row")
    matching_post = posts_payload.fetch("data").find do |row|
      row["author_username"] == profile.username
    end
    expect(matching_post).to be_present
  end

  it "returns valid admin JSON payloads for issues and storage ingestions" do
    get "/admin/issues.json", params: { page: 1, size: 10, sort: [].to_json, filter: [].to_json }
    expect(response).to have_http_status(:ok)
    issues_payload = JSON.parse(response.body)
    expect(issues_payload).to include("data", "last_page", "last_row")

    get "/admin/storage_ingestions.json", params: { page: 1, size: 10, sort: [].to_json, filter: [].to_json }
    expect(response).to have_http_status(:ok)
    ingestions_payload = JSON.parse(response.body)
    expect(ingestions_payload).to include("data", "last_page", "last_row")
  end
end
