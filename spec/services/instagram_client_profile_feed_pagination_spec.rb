require "rails_helper"
require "securerandom"

RSpec.describe "InstagramClientProfileFeedPaginationTest" do
  it "profile feed fetch paginates using next_max_id and aggregates pages" do
    account = InstagramAccount.create!(username: "acct_#{SecureRandom.hex(4)}")
    client = Instagram::Client.new(account: account)

    calls = []
    pages = {
      nil => {
        "items" => [ { "pk" => "1" }, { "pk" => "2" } ],
        "next_max_id" => "cursor_2",
        "more_available" => true
      },
      "cursor_2" => {
        "items" => [ { "pk" => "3" } ],
        "next_max_id" => "",
        "more_available" => false
      }
    }

    client.define_singleton_method(:fetch_user_feed) do |user_id:, referer_username:, count:, max_id: nil|
      calls << { user_id: user_id, username: referer_username, count: count, max_id: max_id }
      pages[max_id]
    end

    result = client.send(
      :fetch_profile_feed_items_via_http,
      username: "target_profile",
      user_id: "42",
      posts_limit: nil
    )

    assert_equal "http_feed_api", result[:source]
    assert_equal "42", result[:user_id]
    assert_equal 2, result[:pages_fetched]
    assert_equal [ "1", "2", "3" ], Array(result[:items]).map { |row| row["pk"] }
    assert_equal [ nil, "cursor_2" ], calls.map { |row| row[:max_id] }
  end

  it "home feed fetch paginates timeline API and de-duplicates repeated items across pages" do
    account = InstagramAccount.create!(username: "acct_#{SecureRandom.hex(4)}")
    client = Instagram::Client.new(account: account)

    timeline_pages = {
      nil => {
        "feed_items" => [
          { "media_or_ad" => feed_media_item(code: "A1", pk: "1", username: "friend_a") },
          { "media_or_ad" => feed_media_item(code: "B1", pk: "2", username: "friend_b") }
        ],
        "next_max_id" => "cursor_2",
        "more_available" => true
      },
      "cursor_2" => {
        "items" => [
          feed_media_item(code: "B1", pk: "2", username: "friend_b"),
          feed_media_item(code: "C1", pk: "3", username: "friend_c")
        ],
        "next_max_id" => "",
        "more_available" => false
      }
    }

    calls = []
    client.define_singleton_method(:fetch_home_feed_timeline_page) do |count:, max_id: nil|
      calls << { count: count, max_id: max_id }
      timeline_pages[max_id]
    end

    result = client.send(:fetch_home_feed_items_via_api_paginated, limit: 3, max_pages: 4)

    assert_equal "api_timeline", result[:source]
    assert_equal 2, result[:pages_fetched]
    assert_equal [ "A1", "B1", "C1" ], Array(result[:items]).map { |row| row[:shortcode] }
    assert_equal [ nil, "cursor_2" ], calls.map { |row| row[:max_id] }
  end

  def feed_media_item(code:, pk:, username:)
    {
      "code" => code,
      "pk" => pk,
      "media_type" => 1,
      "product_type" => "feed",
      "user" => {
        "username" => username,
        "pk" => "u#{pk}"
      },
      "image_versions2" => {
        "candidates" => [
          {
            "url" => "https://cdn.example.com/#{code}.jpg",
            "width" => 1080,
            "height" => 1080
          }
        ]
      }
    }
  end
end
