require "rails_helper"
require "securerandom"

RSpec.describe Instagram::Client do
  let(:account) { InstagramAccount.create!(username: "acct_#{SecureRandom.hex(4)}") }
  let(:client) { described_class.new(account: account) }

  before do
    client.define_singleton_method(:with_task_capture) do |driver:, task_name:, meta: {}, &blk|
      blk.call
    end
  end

  it "collects story users through the API path with the active driver context" do
    driver = instance_double("Selenium::WebDriver::Driver")
    captured_driver = nil
    expected = { "story_alpha" => { display_name: "Story Alpha" } }

    client.define_singleton_method(:fetch_story_users_via_api) do |driver: nil|
      captured_driver = driver
      expected
    end

    result = client.send(:collect_story_users, driver)

    expect(captured_driver).to eq(driver)
    expect(result).to eq(expected)
  end

  it "collects conversation users through the API path with the active driver context" do
    driver = instance_double("Selenium::WebDriver::Driver")
    captured_driver = nil
    captured_limit = nil
    expected = { "dm_alpha" => { display_name: "DM Alpha" } }

    client.define_singleton_method(:fetch_conversation_users_via_api) do |limit:, driver: nil|
      captured_limit = limit
      captured_driver = driver
      expected
    end

    result = client.send(:collect_conversation_users, driver)

    expect(captured_limit).to eq(120)
    expect(captured_driver).to eq(driver)
    expect(result).to eq(expected)
  end

  it "collects follower/following lists through friendships API with driver-backed fallback support" do
    driver = instance_double("Selenium::WebDriver::Driver")
    captured = {}
    expected = { "follow_alpha" => { display_name: "Follow Alpha" } }

    client.define_singleton_method(:fetch_follow_list_via_api) do |profile_username:, list_kind:, driver: nil|
      captured = { profile_username: profile_username, list_kind: list_kind, driver: driver }
      expected
    end

    result = client.send(:collect_follow_list, driver, list_kind: :followers, profile_username: "target_user")

    expect(captured).to eq(profile_username: "target_user", list_kind: :followers, driver: driver)
    expect(result).to eq(expected)
  end

  it "requests web_profile_info via ig_api_get_json with endpoint metadata and retries" do
    driver = Object.new
    captured = {}

    client.define_singleton_method(:ig_api_get_json) do |**kwargs|
      captured = kwargs
      { "data" => { "user" => { "id" => "123" } } }
    end

    result = client.fetch_web_profile_info("Target.User", driver: driver)

    expect(result.dig("data", "user", "id")).to eq("123")
    expect(captured[:path]).to include("/api/v1/users/web_profile_info/?username=target.user")
    expect(captured[:endpoint]).to eq("users/web_profile_info")
    expect(captured[:driver]).to eq(driver)
    expect(captured[:retries]).to eq(2)
  end

  it "requests story reels via ig_api_get_json with driver-backed fallback context" do
    driver = Object.new
    captured = {}
    allow(client).to receive(:debug_story_reel_data)

    client.define_singleton_method(:ig_api_get_json) do |**kwargs|
      captured = kwargs
      { "reels" => { "123" => { "items" => [ { "id" => "story_1" } ] } } }
    end

    reel = client.send(:fetch_story_reel, user_id: "123", referer_username: "Target.User", driver: driver)

    expect(captured[:path]).to eq("/api/v1/feed/reels_media/?reel_ids=123")
    expect(captured[:referer]).to eq("https://www.instagram.com/target.user/")
    expect(captured[:endpoint]).to eq("feed/reels_media")
    expect(captured[:username]).to eq("target.user")
    expect(captured[:driver]).to eq(driver)
    expect(captured[:retries]).to eq(2)
    expect(reel).to eq({ "items" => [ { "id" => "story_1" } ] })
  end

  it "propagates driver context through fetch_story_items_via_api before fallback scraping is considered" do
    driver = Object.new
    captured = {}
    cache = {}

    client.define_singleton_method(:fetch_web_profile_info) do |username, driver: nil|
      captured[:web_info] = { username: username, driver: driver }
      { "data" => { "user" => { "id" => "777" } } }
    end
    client.define_singleton_method(:fetch_story_reel) do |user_id:, referer_username:, driver: nil|
      captured[:reel] = { user_id: user_id, referer_username: referer_username, driver: driver }
      {
        "items" => [
          {
            "id" => "9001_777",
            "media_type" => 1,
            "image_versions2" => { "candidates" => [ { "url" => "https://cdn.example/story.jpg" } ] },
            "user" => { "id" => "777", "username" => "target.user" }
          }
        ]
      }
    end

    stories = client.send(:fetch_story_items_via_api, username: "Target.User", cache: cache, driver: driver)

    expect(captured[:web_info]).to eq(username: "target.user", driver: driver)
    expect(captured[:reel]).to eq(user_id: "777", referer_username: "target.user", driver: driver)
    expect(stories.first[:story_id]).to eq("9001")
    expect(cache.dig("stories:target.user", :items)).to eq(stories)
  end

  it "retries API GET requests before succeeding" do
    attempts = 0
    allow(client).to receive(:sleep)

    client.define_singleton_method(:perform_ig_api_get) do |uri:, referer:|
      attempts += 1
      attempts == 1 ? { ok: false, status: 500, reason: "http_500", body: "temporary" } : { ok: true, status: 200, body: "{\"ok\":true}" }
    end
    client.define_singleton_method(:ig_api_get_json_via_browser) do |driver:, path:|
      raise "browser fallback should not be used"
    end
    client.define_singleton_method(:log_ig_api_get_failure) do |**|
      raise "final failure should not be logged"
    end

    result = client.send(
      :ig_api_get_json,
      path: "/api/v1/test_endpoint/",
      referer: "https://www.instagram.com/",
      endpoint: "test_endpoint",
      username: "demo_user",
      retries: 2
    )

    expect(result).to eq({ "ok" => true })
    expect(attempts).to eq(2)
  end

  it "uses browser API fallback when direct API GET retries fail" do
    attempts = 0
    logged = false
    allow(client).to receive(:sleep)

    client.define_singleton_method(:perform_ig_api_get) do |uri:, referer:|
      attempts += 1
      { ok: false, status: 429, reason: "http_429", body: "rate_limited" }
    end
    client.define_singleton_method(:ig_api_get_json_via_browser) do |driver:, path:|
      { ok: true, status: 200, reason: nil, payload: { "data" => { "ok" => true } }, body: "" }
    end
    client.define_singleton_method(:log_ig_api_get_failure) do |**|
      logged = true
    end

    result = client.send(
      :ig_api_get_json,
      path: "/api/v1/test_endpoint/",
      referer: "https://www.instagram.com/",
      endpoint: "test_endpoint",
      username: "demo_user",
      driver: Object.new,
      retries: 1
    )

    expect(result).to eq({ "data" => { "ok" => true } })
    expect(attempts).to eq(2)
    expect(logged).to eq(false)
  end
end
