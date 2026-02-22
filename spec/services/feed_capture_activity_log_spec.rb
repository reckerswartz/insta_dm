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
end
