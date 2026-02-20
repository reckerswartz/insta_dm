require "rails_helper"
require "securerandom"
require "stringio"

RSpec.describe InstagramAccounts::StoryArchiveQuery do
  it "returns paginated story archive events scoped to account and optional date" do
    account = InstagramAccount.create!(username: "acct_#{SecureRandom.hex(4)}")
    profile = InstagramProfile.create!(instagram_account: account, username: "profile_#{SecureRandom.hex(3)}")

    older = profile.instagram_profile_events.create!(
      kind: "story_downloaded",
      external_id: "evt_#{SecureRandom.hex(4)}",
      detected_at: 3.hours.ago,
      occurred_at: Date.current.to_time.beginning_of_day + 2.hours,
      metadata: {}
    )
    older.media.attach(io: StringIO.new("older"), filename: "older.jpg", content_type: "image/jpeg")

    newer = profile.instagram_profile_events.create!(
      kind: "story_media_downloaded_via_feed",
      external_id: "evt_#{SecureRandom.hex(4)}",
      detected_at: 1.hour.ago,
      occurred_at: Date.current.to_time.beginning_of_day + 4.hours,
      metadata: {}
    )
    newer.media.attach(io: StringIO.new("newer"), filename: "newer.jpg", content_type: "image/jpeg")

    result = described_class.new(
      account: account,
      page: "1",
      per_page: "8",
      on: Date.current.iso8601
    ).call

    expect(result.page).to eq(1)
    expect(result.per_page).to eq(8)
    expect(result.total).to eq(2)
    expect(result.on).to eq(Date.current)
    expect(result.events.map(&:id)).to eq([newer.id, older.id])
  end

  it "returns nil date filter for invalid date values" do
    account = InstagramAccount.create!(username: "acct_#{SecureRandom.hex(4)}")
    profile = InstagramProfile.create!(instagram_account: account, username: "profile_#{SecureRandom.hex(3)}")
    event = profile.instagram_profile_events.create!(
      kind: "story_downloaded",
      external_id: "evt_#{SecureRandom.hex(4)}",
      detected_at: Time.current,
      metadata: {}
    )
    event.media.attach(io: StringIO.new("one"), filename: "one.jpg", content_type: "image/jpeg")

    result = described_class.new(account: account, page: 1, per_page: 12, on: "invalid-date").call

    expect(result.on).to be_nil
    expect(result.total).to eq(1)
  end
end
