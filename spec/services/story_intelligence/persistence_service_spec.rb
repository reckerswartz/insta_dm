require "rails_helper"
require "securerandom"

RSpec.describe StoryIntelligence::PersistenceService do
  def build_event
    account = InstagramAccount.create!(username: "acct_#{SecureRandom.hex(4)}")
    profile = account.instagram_profiles.create!(username: "profile_#{SecureRandom.hex(4)}")
    event = profile.instagram_profile_events.create!(
      kind: "story_analyzed",
      external_id: "story_#{SecureRandom.hex(5)}",
      detected_at: Time.current,
      metadata: {}
    )
    [profile, event]
  end

  it "syncs persisted local intelligence into profile insight store" do
    profile, event = build_event

    described_class.new(event: event).persist_local_intelligence!(
      {
        source: "local_pipeline",
        topics: ["travel", "city"],
        hashtags: ["#trip"],
        mentions: ["@friend"],
        ocr_text: "travel day"
      }
    )

    profile.reload
    store = profile.instagram_profile_behavior_profile&.metadata&.dig("ai_signal_store")
    expect(store).to be_a(Hash)

    topic_values = Array(store.dig("signals", "topics")).map { |row| row["value"] }
    expect(topic_values).to include("travel", "city")
  end

  it "does not duplicate insight store counts for unchanged story intelligence" do
    profile, event = build_event
    service = described_class.new(event: event)
    payload = {
      source: "local_pipeline",
      topics: ["fitness"],
      hashtags: ["#gym"]
    }

    service.persist_local_intelligence!(payload)
    store_first = profile.reload.instagram_profile_behavior_profile.metadata.dig("ai_signal_store")
    first_count = Array(store_first.dig("signals", "topics")).find { |row| row["value"] == "fitness" }["count"]

    service.persist_local_intelligence!(payload)
    store_second = profile.reload.instagram_profile_behavior_profile.metadata.dig("ai_signal_store")
    second_count = Array(store_second.dig("signals", "topics")).find { |row| row["value"] == "fitness" }["count"]

    expect(second_count).to eq(first_count)
  end
end
