require "rails_helper"

RSpec.describe Instagram::Client::StoryScraper::SyncStats do
  it "starts with the default story sync counters" do
    stats = described_class.new

    expect(stats).to include(
      stories_visited: 0,
      downloaded: 0,
      analyzed: 0,
      commented: 0,
      reacted: 0,
      skipped_video: 0,
      skipped_not_tagged: 0,
      skipped_ads: 0,
      skipped_invalid_media: 0,
      skipped_unreplyable: 0,
      skipped_out_of_network: 0,
      skipped_interaction_retry: 0,
      skipped_reshared_external_link: 0,
      failed: 0
    )
  end

  it "supports override initialization and counter increments" do
    stats = described_class.new(downloaded: 3)

    stats.increment!(:downloaded)
    stats.increment!("failed", by: 2)

    expect(stats[:downloaded]).to eq(4)
    expect(stats[:failed]).to eq(2)
  end
end
