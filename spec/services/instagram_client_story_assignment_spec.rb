require "rails_helper"
require "securerandom"

RSpec.describe "InstagramClientStoryAssignmentTest" do
  it "normalized story context prefers canonical numeric story id from live url" do
    account = InstagramAccount.create!(username: "acct_#{SecureRandom.hex(4)}")
    client = Instagram::Client.new(account: account)
    driver = Struct.new(:current_url).new("https://www.instagram.com/stories/reenapandey6668/3834650166490093993/")

    context = {
      ref: "reenapandey6668:sig:StoriesInstagramhttps:scontent-del3-1cdninstagramcomvt5",
      username: "reenapandey6668",
      story_id: "",
      story_key: "reenapandey6668:sig:StoriesInstagramhttps:scontent-del3-1cdninstagramcomvt5"
    }

    normalized = client.send(:normalized_story_context_for_processing, driver: driver, context: context)

    assert_equal "reenapandey6668", normalized[:username]
    assert_equal "3834650166490093993", normalized[:story_id]
    assert_equal "reenapandey6668:3834650166490093993", normalized[:ref]
    assert_equal "reenapandey6668:3834650166490093993", normalized[:story_key]
    assert_equal "https://www.instagram.com/stories/reenapandey6668/3834650166490093993/", normalized[:url]
  end
  it "story id hint extraction decodes ig_cache_key media id" do
    account = InstagramAccount.create!(username: "acct_#{SecureRandom.hex(4)}")
    client = Instagram::Client.new(account: account)

    media_url = "https://scontent-del3-1.cdninstagram.com/v/t51.71878-15/629347672_1333375088811937_7325738075121317613_n.jpg?stp=dst-jpg_e15_tt6&_nc_cat=104&ig_cache_key=MzgzNDcxMjc4MzIyMTY2NjUwMw%3D%3D.3-ccb7-5&ccb=7-5"
    hinted_story_id = client.send(:story_id_hint_from_media_url, media_url)

    assert_equal "3834712783221666503", hinted_story_id
  end
  it "resolve_story_media_for_current_context is api only when story cannot be resolved" do
    account = InstagramAccount.create!(username: "acct_#{SecureRandom.hex(4)}")
    client = Instagram::Client.new(account: account)
    client.define_singleton_method(:resolve_story_item_via_api) { |username:, story_id:, cache:| nil }

    media = client.send(
      :resolve_story_media_for_current_context,
      driver: Struct.new(:current_url).new("https://www.instagram.com/stories/example/123/"),
      username: "example",
      story_id: "123",
      fallback_story_key: "example:123",
      cache: {}
    )

    assert_equal "api_unresolved", media[:source]
    assert_nil media[:url]
    assert_equal "123", media[:story_id]
  end

  it "resolve_story_media_for_current_context ignores non-http dom media urls" do
    account = InstagramAccount.create!(username: "acct_#{SecureRandom.hex(4)}")
    client = Instagram::Client.new(account: account)
    client.define_singleton_method(:resolve_story_item_via_api) { |username:, story_id:, cache:| nil }
    client.define_singleton_method(:resolve_story_item_via_dom) do |driver:|
      {
        media_url: "blob:https://www.instagram.com/823994bd-fce1-483b-9eba-694351816693",
        media_type: "video",
        image_url: "",
        video_url: "",
        width: 720,
        height: 1280
      }
    end

    media = client.send(
      :resolve_story_media_for_current_context,
      driver: Struct.new(:current_url).new("https://www.instagram.com/stories/example/123/"),
      username: "example",
      story_id: "123",
      fallback_story_key: "example:123",
      cache: {}
    )

    assert_equal "api_unresolved", media[:source]
    assert_nil media[:url]
    assert_equal "123", media[:story_id]
  end

  it "resolve_story_media_for_current_context falls back to performance logs when api and dom fail" do
    account = InstagramAccount.create!(username: "acct_#{SecureRandom.hex(4)}")
    client = Instagram::Client.new(account: account)
    client.define_singleton_method(:resolve_story_item_via_api) { |username:, story_id:, cache:| nil }
    client.define_singleton_method(:resolve_story_item_via_dom) { |driver:| nil }

    perf_payload = {
      "message" => {
        "method" => "Network.responseReceived",
        "params" => {
          "response" => {
            "status" => 200,
            "mimeType" => "video/mp4",
            "url" => "https://scontent-del3-2.cdninstagram.com/o1/v/t2/f2/m78/story_sample.mp4?abc=1"
          }
        }
      }
    }

    perf_entry = Struct.new(:message).new(JSON.generate(perf_payload))
    logs = double("logs")
    allow(logs).to receive(:available_types).and_return([ :performance ])
    allow(logs).to receive(:get).with(:performance).and_return([ perf_entry ])
    driver = double("driver", logs: logs, current_url: "https://www.instagram.com/stories/example/123/")

    media = client.send(
      :resolve_story_media_for_current_context,
      driver: driver,
      username: "example",
      story_id: "123",
      fallback_story_key: "example:123",
      cache: {}
    )

    assert_equal "performance_logs_media", media[:source]
    assert_equal "video", media[:media_type]
    assert_equal "https://scontent-del3-2.cdninstagram.com/o1/v/t2/f2/m78/story_sample.mp4?abc=1", media[:url]
    assert_equal "123", media[:story_id]
  end

  it "extract_story_item keeps carousel media metadata from api payload" do
    account = InstagramAccount.create!(username: "acct_#{SecureRandom.hex(4)}")
    client = Instagram::Client.new(account: account)

    payload = {
      "id" => "1234567890123456789_1",
      "media_type" => 8,
      "carousel_media" => [
        {
          "id" => "c1_1",
          "media_type" => 1,
          "image_versions2" => { "candidates" => [ { "url" => "https://cdn.example.com/image.jpg", "width" => 720, "height" => 1280 } ] }
        },
        {
          "id" => "c2_1",
          "media_type" => 2,
          "image_versions2" => { "candidates" => [ { "url" => "https://cdn.example.com/video_poster.jpg", "width" => 720, "height" => 1280 } ] },
          "video_versions" => [ { "url" => "https://cdn.example.com/video.mp4", "width" => 720, "height" => 1280 } ]
        }
      ],
      "user" => { "id" => "42", "username" => "carousel_user" },
      "can_reply" => true,
      "can_reshare" => true
    }

    story = client.send(:extract_story_item, payload, username: "carousel_user", reel_owner_id: "42")

    assert_equal "1234567890123456789", story[:story_id]
    assert_equal "video", story[:media_type]
    assert_equal "https://cdn.example.com/video.mp4", story[:media_url]
    assert_equal "carousel_media", story[:primary_media_source]
    assert_equal 2, story[:primary_media_index]
    assert_equal 2, Array(story[:media_variants]).length
    assert_equal 2, Array(story[:carousel_media]).length
  end

  it "extract_story_item normalizes relative media urls to absolute instagram urls" do
    account = InstagramAccount.create!(username: "acct_#{SecureRandom.hex(4)}")
    client = Instagram::Client.new(account: account)

    payload = {
      "id" => "2234567890123456789_1",
      "media_type" => 1,
      "image_versions2" => { "candidates" => [ { "url" => "/v/t51.2885-15/relative_story.jpg", "width" => 720, "height" => 1280 } ] },
      "user" => { "id" => "99", "username" => "relative_user" }
    }

    story = client.send(:extract_story_item, payload, username: "relative_user", reel_owner_id: "99")

    assert_equal "https://www.instagram.com/v/t51.2885-15/relative_story.jpg", story[:media_url]
    assert_equal "https://www.instagram.com/v/t51.2885-15/relative_story.jpg", story[:image_url]
  end

  it "find_existing_story_download_for_profile matches canonical and legacy external ids" do
    account = InstagramAccount.create!(username: "acct_#{SecureRandom.hex(4)}")
    profile = InstagramProfile.create!(instagram_account: account, username: "profile_#{SecureRandom.hex(3)}")
    client = Instagram::Client.new(account: account)

    canonical = profile.instagram_profile_events.create!(
      kind: "story_downloaded",
      external_id: "story_downloaded:123456",
      occurred_at: Time.current,
      detected_at: Time.current,
      metadata: { "story_id" => "123456" }
    )
    profile.instagram_profile_events.create!(
      kind: "story_downloaded",
      external_id: "story_downloaded:789012:2026-02-20T00:00:00Z",
      occurred_at: Time.current,
      detected_at: Time.current,
      metadata: {}
    )

    found_canonical = client.send(:find_existing_story_download_for_profile, profile: profile, story_id: "123456")
    found_legacy = client.send(:find_existing_story_download_for_profile, profile: profile, story_id: "789012")

    expect(found_canonical.id).to eq(canonical.id)
    expect(found_legacy.external_id).to include("story_downloaded:789012:")
  end
end
