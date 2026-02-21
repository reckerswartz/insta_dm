require "rails_helper"
require "securerandom"

RSpec.describe "InstagramClientMutualFriendsTest" do
  it "uses friendships mutual_friends API endpoint" do
    account = InstagramAccount.create!(username: "acct_#{SecureRandom.hex(4)}")

    client = Instagram::Client.new(account: account)
    requested_paths = []
    requested_referers = []

    client.define_singleton_method(:fetch_web_profile_info) do |_username|
      { "data" => { "user" => { "id" => "12345" } } }
    end

    client.define_singleton_method(:ig_api_get_json) do |path:, referer:, **_|
      requested_paths << path
      requested_referers << referer
      {
        "users" => [
          {
            "username" => "mutual_alpha",
            "full_name" => "Mutual Alpha",
            "profile_pic_url" => "https://cdn.example.com/a.jpg"
          }
        ],
        "next_max_id" => ""
      }
    end

    result = client.fetch_mutual_friends(profile_username: "target_profile", limit: 10)

    assert_equal [ "mutual_alpha" ], result.map { |row| row[:username] }
    assert_equal "Mutual Alpha", result.first[:display_name]
    assert_equal "/api/v1/friendships/12345/mutual_friends/", requested_paths.first.split("?").first
    assert_equal "https://www.instagram.com/target_profile/", requested_referers.first
  end

  it "returns empty when target user id cannot be resolved" do
    account = InstagramAccount.create!(username: "acct_#{SecureRandom.hex(4)}")
    client = Instagram::Client.new(account: account)
    client.define_singleton_method(:fetch_web_profile_info) { |_username| nil }

    result = client.fetch_mutual_friends(profile_username: "unknown_profile")

    assert_equal [], result
  end
end
