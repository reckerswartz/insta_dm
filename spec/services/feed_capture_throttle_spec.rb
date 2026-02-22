require "rails_helper"
require "securerandom"

RSpec.describe FeedCaptureThrottle do
  it "reserves a slot and stamps the account timestamp when not locked" do
    account = InstagramAccount.create!(username: "acct_#{SecureRandom.hex(4)}")
    now = Time.current

    reservation = described_class.reserve!(account: account, now: now)

    expect(reservation.reserved).to eq(true)
    expect(reservation.remaining_seconds).to eq(0)
    expect(account.reload.continuous_processing_last_feed_sync_enqueued_at).to be_present
  end

  it "rejects reservation while still inside throttle window" do
    now = Time.current
    account = InstagramAccount.create!(
      username: "acct_#{SecureRandom.hex(4)}",
      continuous_processing_last_feed_sync_enqueued_at: now
    )

    reservation = described_class.reserve!(account: account, now: now + 5.seconds)

    expect(reservation.reserved).to eq(false)
    expect(reservation.remaining_seconds).to be > 0
  end

  it "releases back to the previous timestamp" do
    previous = 2.hours.ago
    account = InstagramAccount.create!(
      username: "acct_#{SecureRandom.hex(4)}",
      continuous_processing_last_feed_sync_enqueued_at: previous
    )

    reservation = described_class.reserve!(account: account, now: Time.current)
    expect(reservation.reserved).to eq(true)

    described_class.release!(account: account, previous_enqueued_at: previous)

    expect(account.reload.continuous_processing_last_feed_sync_enqueued_at.to_i).to eq(previous.to_i)
  end
end
