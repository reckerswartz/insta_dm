require "rails_helper"
require "securerandom"

RSpec.describe Instagram::Client do
  it "falls back to deterministic suggestions when engagement generator fails" do
    account = InstagramAccount.create!(username: "acct_#{SecureRandom.hex(4)}")
    client = described_class.new(account: account)

    allow(Ai::LocalEngagementCommentGenerator).to receive(:new).and_raise("generator_down")

    suggestions = client.send(
      :generate_google_engagement_comments!,
      payload: {},
      image_description: "City skyline at sunset.",
      topics: [ "city" ],
      author_type: "creator"
    )

    expect(suggestions).to be_an(Array)
    expect(suggestions).not_to be_empty
    expect(suggestions.join(" ")).to include("city")
  end

  it "skips feed auto-engagement for sponsored items before downloading media" do
    account = InstagramAccount.create!(username: "acct_#{SecureRandom.hex(4)}")
    profile = account.instagram_profiles.create!(
      username: "friend_#{SecureRandom.hex(3)}",
      following: true,
      follows_you: true
    )
    client = described_class.new(account: account)
    driver = instance_double("SeleniumDriver")
    allow(client).to receive(:capture_task_html)

    item = {
      shortcode: "post_#{SecureRandom.hex(3)}",
      author_username: profile.username,
      media_url: "https://cdn.example.com/post.jpg",
      caption: "Sponsored",
      metadata: { "source" => "api_timeline", "ad_id" => "123" }
    }

    expect(client).not_to receive(:download_media_with_metadata)
    result = client.send(:auto_engage_feed_post!, driver: driver, item: item)

    expect(result[:skipped]).to eq(true)
    expect(result[:skip_reason]).to eq("sponsored_or_ad")
    expect(result[:comment_posted]).to eq(false)
  end

  it "skips feed auto-engagement for profiles outside the follow graph" do
    account = InstagramAccount.create!(username: "acct_#{SecureRandom.hex(4)}")
    profile = account.instagram_profiles.create!(
      username: "stranger_#{SecureRandom.hex(3)}",
      following: false,
      follows_you: false
    )
    client = described_class.new(account: account)
    driver = instance_double("SeleniumDriver")
    allow(client).to receive(:capture_task_html)

    item = {
      shortcode: "post_#{SecureRandom.hex(3)}",
      author_username: profile.username,
      media_url: "https://cdn.example.com/post.jpg",
      caption: "Hello",
      metadata: { "source" => "dom_fallback" }
    }

    expect(client).not_to receive(:download_media_with_metadata)
    result = client.send(:auto_engage_feed_post!, driver: driver, item: item)

    expect(result[:skipped]).to eq(true)
    expect(result[:skip_reason]).to eq("profile_not_in_follow_graph")
    expect(result[:comment_posted]).to eq(false)
  end

  it "skips feed auto-engagement when media trust policy blocks the source" do
    account = InstagramAccount.create!(username: "acct_#{SecureRandom.hex(4)}")
    profile = account.instagram_profiles.create!(
      username: "friend_#{SecureRandom.hex(3)}",
      following: true,
      follows_you: true
    )
    client = described_class.new(account: account)
    driver = instance_double("SeleniumDriver")
    allow(client).to receive(:capture_task_html)
    allow(client).to receive(:log_automation_event)

    item = {
      shortcode: "post_#{SecureRandom.hex(3)}",
      author_username: profile.username,
      media_url: "https://cdn.example.com/post.jpg?ad_urlgen=1",
      caption: "Hello",
      metadata: { "source" => "dom_fallback" }
    }

    expect(client).not_to receive(:download_media_with_metadata)
    result = client.send(:auto_engage_feed_post!, driver: driver, item: item)

    expect(result[:skipped]).to eq(true)
    expect(result[:skip_reason]).to eq("ad_related_media_source")
    expect(result[:comment_posted]).to eq(false)
  end

  it "skips feed auto-engagement when resolved profile is not connected" do
    account = InstagramAccount.create!(username: "acct_#{SecureRandom.hex(4)}")
    profile = account.instagram_profiles.create!(
      username: "stranger_#{SecureRandom.hex(3)}",
      following: false,
      follows_you: false
    )
    client = described_class.new(account: account)
    driver = instance_double("SeleniumDriver")
    allow(client).to receive(:capture_task_html)
    allow(client).to receive(:log_automation_event)
    allow(client).to receive(:resolve_feed_profile_for_action).and_return({ profile: profile, reason: nil })

    item = {
      shortcode: "post_#{SecureRandom.hex(3)}",
      author_username: profile.username,
      media_url: "https://cdn.example.com/post.jpg",
      caption: "Hello",
      metadata: { "source" => "api_timeline" }
    }

    expect(client).not_to receive(:download_media_with_metadata)
    result = client.send(:auto_engage_feed_post!, driver: driver, item: item)

    expect(result[:skipped]).to eq(true)
    expect(result[:skip_reason]).to eq("profile_not_connected")
    expect(result[:comment_posted]).to eq(false)
  end

  it "skips story auto-engagement before download when media trust policy blocks the source" do
    account = InstagramAccount.create!(username: "acct_#{SecureRandom.hex(4)}")
    profile = account.instagram_profiles.create!(
      username: "friend_#{SecureRandom.hex(3)}",
      following: true,
      follows_you: true
    )
    client = described_class.new(account: account)
    driver = instance_double("SeleniumDriver")

    allow(client).to receive(:capture_task_html)
    allow(client).to receive(:log_automation_event)
    allow(client).to receive(:fetch_story_users_via_api).and_return({ profile.username => {} })
    allow(client).to receive(:fetch_story_items_via_api).and_return(
      [
        {
          story_id: "story_#{SecureRandom.hex(2)}",
          media_url: "https://cdn.example.com/story.jpg?ad_urlgen=1",
          can_reply: true,
          media_type: "image"
        }
      ]
    )

    expect(client).not_to receive(:download_media_with_metadata)
    result = client.send(:auto_engage_first_story!, driver: driver, story_hold_seconds: 0)

    expect(result[:attempted]).to eq(true)
    expect(result[:reply_skipped]).to eq(true)
    expect(result[:reply_skip_reason]).to eq("ad_related_media_source")
  end
end
