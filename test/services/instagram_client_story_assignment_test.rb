require "test_helper"
require "securerandom"

class InstagramClientStoryAssignmentTest < ActiveSupport::TestCase
  test "normalized story context prefers canonical numeric story id from live url" do
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

  test "story id hint extraction decodes ig_cache_key media id" do
    account = InstagramAccount.create!(username: "acct_#{SecureRandom.hex(4)}")
    client = Instagram::Client.new(account: account)

    media_url = "https://scontent-del3-1.cdninstagram.com/v/t51.71878-15/629347672_1333375088811937_7325738075121317613_n.jpg?stp=dst-jpg_e15_tt6&_nc_cat=104&ig_cache_key=MzgzNDcxMjc4MzIyMTY2NjUwMw%3D%3D.3-ccb7-5&ccb=7-5"
    hinted_story_id = client.send(:story_id_hint_from_media_url, media_url)

    assert_equal "3834712783221666503", hinted_story_id
  end

  test "resolve_story_media_for_current_context is api only when story cannot be resolved" do
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

  test "extract_story_item keeps carousel media metadata from api payload" do
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
end
