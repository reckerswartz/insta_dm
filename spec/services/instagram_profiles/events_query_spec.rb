require "rails_helper"
require "securerandom"

RSpec.describe InstagramProfiles::EventsQuery do
  it "applies tabulator kind filter, query search, and sorter" do
    account = InstagramAccount.create!(username: "acct_#{SecureRandom.hex(4)}")
    profile = account.instagram_profiles.create!(username: "profile_#{SecureRandom.hex(3)}")

    profile.instagram_profile_events.create!(
      kind: "story_downloaded",
      external_id: "ignore_#{SecureRandom.hex(3)}",
      detected_at: 2.hours.ago,
      occurred_at: 2.hours.ago
    )
    target = profile.instagram_profile_events.create!(
      kind: "story_media_downloaded_via_feed",
      external_id: "match_token_#{SecureRandom.hex(3)}",
      detected_at: 1.hour.ago,
      occurred_at: 1.hour.ago
    )

    params = ActionController::Parameters.new(
      filters: [ { field: "kind", value: "media_downloaded" } ].to_json,
      q: "match_token",
      sorters: [ { "field" => "occurred_at", "dir" => "asc" } ].to_json,
      per_page: 25
    )
    result = described_class.new(profile: profile, params: params).call

    expect(result.total).to eq(1)
    expect(result.pages).to eq(1)
    expect(result.events.map(&:id)).to eq([target.id])
  end

  it "defaults to detected_at desc ordering when remote sorter is invalid" do
    account = InstagramAccount.create!(username: "acct_#{SecureRandom.hex(4)}")
    profile = account.instagram_profiles.create!(username: "profile_#{SecureRandom.hex(3)}")
    older = profile.instagram_profile_events.create!(kind: "story_downloaded", external_id: "a_#{SecureRandom.hex(2)}", detected_at: 3.hours.ago)
    newer = profile.instagram_profile_events.create!(kind: "story_downloaded", external_id: "b_#{SecureRandom.hex(2)}", detected_at: 1.hour.ago)

    params = ActionController::Parameters.new(sorters: [ { "field" => "unknown", "dir" => "asc" } ].to_json, per_page: 20)
    result = described_class.new(profile: profile, params: params).call

    expect(result.total).to eq(2)
    expect(result.events.map(&:id)).to eq([newer.id, older.id])
  end
end
