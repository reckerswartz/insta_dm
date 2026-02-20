require "rails_helper"
require "securerandom"

RSpec.describe Instagram::Client::StoryScraperService do
  it "includes the extracted story sync modules" do
    expect(described_class.included_modules.map(&:name)).to include(
      "Instagram::Client::StoryScraper::HomeCarouselSync",
      "Instagram::Client::StoryScraper::CarouselOpening",
      "Instagram::Client::StoryScraper::CarouselNavigation"
    )
  end

  it "resolves story scraper entrypoints from extracted modules" do
    account = InstagramAccount.create!(username: "acct_#{SecureRandom.hex(4)}")
    client = Instagram::Client.new(account: account)

    expect(client).to respond_to(:sync_home_story_carousel!)
    expect(client.method(:sync_home_story_carousel!).owner.name).to eq("Instagram::Client::StoryScraper::HomeCarouselSync")
    expect(client.method(:open_first_story_from_home_carousel!).owner.name).to eq("Instagram::Client::StoryScraper::CarouselOpening")
    expect(client.method(:click_next_story_in_carousel!).owner.name).to eq("Instagram::Client::StoryScraper::CarouselNavigation")
  end

  it "recovers a numeric story id from media URL hints when context id is missing" do
    account = InstagramAccount.create!(username: "acct_#{SecureRandom.hex(4)}")
    client = Instagram::Client.new(account: account)

    recovered = client.send(
      :resolve_story_id_for_processing,
      current_story_id: "",
      ref: "sample_user:",
      live_url: "https://www.instagram.com/stories/sample_user/",
      media: {
        url: "https://cdninstagram.example/media.jpg?ig_cache_key=MzgzNjg1MjIzODE2NTMzODc5Mg%3D%3D"
      }
    )

    expect(recovered).to eq("3836852238165338792")
  end

  it "marks api_story_media_unavailable as retryable when API is rate limited" do
    account = InstagramAccount.create!(username: "acct_#{SecureRandom.hex(4)}")
    client = Instagram::Client.new(account: account)

    payload = client.send(
      :story_sync_failure_metadata,
      reason: "api_story_media_unavailable",
      error: nil,
      story_id: "3836852238165338792",
      story_ref: "sample_user:3836852238165338792",
      story_url: "https://www.instagram.com/stories/sample_user/3836852238165338792/",
      api_rate_limited: true,
      api_failure_status: 429
    )

    expect(payload["retryable"] || payload[:retryable]).to eq(true)
    expect(payload["failure_category"] || payload[:failure_category]).to eq("throttled")
  end
end
