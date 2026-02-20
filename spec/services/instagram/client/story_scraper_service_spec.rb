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

    expect(client.method(:sync_home_story_carousel!).owner.name).to eq("Instagram::Client::StoryScraper::HomeCarouselSync")
    expect(client.method(:open_first_story_from_home_carousel!).owner.name).to eq("Instagram::Client::StoryScraper::CarouselOpening")
    expect(client.method(:click_next_story_in_carousel!).owner.name).to eq("Instagram::Client::StoryScraper::CarouselNavigation")
  end
end
