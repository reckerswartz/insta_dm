require "rails_helper"
require "securerandom"

RSpec.describe FeedCaptureActivityLog do
  before do
    described_class.clear!
  end

  it "appends and returns recent entries in reverse chronological order" do
    account = InstagramAccount.create!(username: "acct_#{SecureRandom.hex(4)}")

    first = described_class.append!(account: account, status: :queued, source: "manual", message: "queued")
    second = described_class.append!(account: account, status: :completed, source: "scheduler", message: "completed")

    entries = described_class.entries_for(account: account, limit: 10)

    expect(first).to be_present
    expect(second).to be_present
    expect(entries.length).to eq(2)
    expect(entries.first[:message]).to eq("completed")
    expect(entries.first[:status]).to eq("succeeded")
    expect(entries.second[:status]).to eq("queued")
  end

  it "ignores blank messages" do
    account = InstagramAccount.create!(username: "acct_#{SecureRandom.hex(4)}")

    expect(described_class.append!(account: account, status: :info, message: " ")).to be_nil
    expect(described_class.entries_for(account: account)).to eq([])
  end

  it "stores structured capture details for feed visibility" do
    account = InstagramAccount.create!(username: "acct_#{SecureRandom.hex(4)}")

    described_class.append!(
      account: account,
      status: :succeeded,
      source: "manual",
      message: "capture complete",
      details: {
        seen_posts: 4,
        new_posts: 2,
        updated_posts: 1,
        downloaded_media_count: 2,
        moved_to_action_queue_count: 2,
        rejected_items_count: 1,
        downloaded_media_items: [ { shortcode: "abc123", username: "friend" } ],
        queued_action_items: [ { shortcode: "abc123", username: "friend" } ],
        rejected_items: [ { shortcode: "zzz111", reason: "suggested_or_irrelevant" } ]
      }
    )

    entry = described_class.entries_for(account: account, limit: 1).first
    expect(entry).to be_present
    expect(entry.dig(:details, :seen_posts)).to eq(4)
    expect(entry.dig(:details, :downloaded_media_count)).to eq(2)
    expect(entry.dig(:details, :downloaded_media_items)).to include(include(shortcode: "abc123"))
    expect(entry.dig(:details, :rejected_items)).to include(include(reason: "suggested_or_irrelevant"))
  end
end
