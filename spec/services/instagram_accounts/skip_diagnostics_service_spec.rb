require "rails_helper"
require "securerandom"

RSpec.describe InstagramAccounts::SkipDiagnosticsService do
  it "aggregates skip reasons and classifies them" do
    account = InstagramAccount.create!(username: "acct_#{SecureRandom.hex(4)}")
    profile = InstagramProfile.create!(instagram_account: account, username: "profile_#{SecureRandom.hex(3)}")

    profile.instagram_profile_events.create!(
      kind: "story_reply_skipped",
      external_id: "evt_#{SecureRandom.hex(4)}",
      detected_at: 2.hours.ago,
      metadata: { "reason" => "profile_not_in_network" }
    )
    profile.instagram_profile_events.create!(
      kind: "story_sync_failed",
      external_id: "evt_#{SecureRandom.hex(4)}",
      detected_at: 90.minutes.ago,
      metadata: { "reason" => "reply_box_not_found" }
    )
    profile.instagram_profile_events.create!(
      kind: "story_ad_skipped",
      external_id: "evt_#{SecureRandom.hex(4)}",
      detected_at: 30.minutes.ago,
      metadata: {}
    )
    profile.instagram_profile_events.create!(
      kind: "story_sync_failed",
      external_id: "evt_#{SecureRandom.hex(4)}",
      detected_at: 20.minutes.ago,
      metadata: { "reason" => "api_story_media_unavailable" }
    )
    profile.instagram_profile_events.create!(
      kind: "story_reply_skipped",
      external_id: "evt_#{SecureRandom.hex(4)}",
      detected_at: 2.days.ago,
      metadata: { "reason" => "profile_not_in_network" }
    )

    summary = described_class.new(account: account, hours: 24).call

    expect(summary[:window_hours]).to eq(24)
    expect(summary[:total]).to eq(4)
    expect(summary[:by_reason]).to include(
      hash_including(reason: "profile_not_in_network", count: 1, classification: "valid"),
      hash_including(reason: "reply_box_not_found", count: 1, classification: "review"),
      hash_including(reason: "story_ad_skipped", count: 1, classification: "valid"),
      hash_including(reason: "api_story_media_unavailable", count: 1, classification: "recoverable", retry_recommended: true)
    )
  end
end
