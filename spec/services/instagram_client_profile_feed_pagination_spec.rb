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
end
