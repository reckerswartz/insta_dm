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
end
