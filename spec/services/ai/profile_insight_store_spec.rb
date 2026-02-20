require "rails_helper"
require "securerandom"

RSpec.describe Ai::ProfileInsightStore do
  def build_profile
    account = InstagramAccount.create!(username: "acct_#{SecureRandom.hex(4)}")
    profile = account.instagram_profiles.create!(username: "profile_#{SecureRandom.hex(4)}")
    [account, profile]
  end

  it "persists reusable structured signals from post analysis and skips unchanged reprocessing" do
    account, profile = build_profile
    post = profile.instagram_profile_posts.create!(
      instagram_account: account,
      shortcode: "post_#{SecureRandom.hex(3)}",
      taken_at: Time.current,
      ai_status: "analyzed",
      likes_count: 22,
      comments_count: 5,
      analysis: {
        "topics" => ["travel", "city"],
        "hashtags" => ["#trip"],
        "mentions" => ["@friend"],
        "image_description" => "Travel day in the city with coffee"
      },
      metadata: {}
    )

    service = described_class.new
    service.ingest_post!(profile: profile, post: post, analysis: post.analysis, metadata: post.metadata)
    profile.reload

    record = profile.instagram_profile_behavior_profile
    expect(record).to be_present

    store = record.metadata.dig("ai_signal_store")
    expect(store).to be_a(Hash)
    expect(Array(store.dig("signals", "topics")).map { |row| row["value"] }).to include("travel", "city")

    previous_count = Array(store.dig("signals", "topics")).find { |row| row["value"] == "travel" }["count"]

    service.ingest_post!(profile: profile, post: post, analysis: post.analysis, metadata: post.metadata)
    profile.reload

    store_after = profile.instagram_profile_behavior_profile.metadata.dig("ai_signal_store")
    count_after = Array(store_after.dig("signals", "topics")).find { |row| row["value"] == "travel" }["count"]

    expect(count_after).to eq(previous_count)
  end

  it "ingests story intelligence for future reuse" do
    account, profile = build_profile
    event = profile.instagram_profile_events.create!(
      kind: "story_analyzed",
      external_id: "story_#{SecureRandom.hex(3)}",
      detected_at: Time.current,
      metadata: {}
    )

    described_class.new.ingest_story!(
      profile: profile,
      event: event,
      intelligence: {
        "topics" => ["celebration", "friends"],
        "hashtags" => ["#birthday"],
        "transcript" => "birthday dinner with friends"
      }
    )

    profile.reload
    store = profile.instagram_profile_behavior_profile.metadata.dig("ai_signal_store")

    expect(Array(store.dig("signals", "topics")).map { |row| row["value"] }).to include("celebration")
    expect(Array(store["history"]).last["type"]).to eq("story")
  end

  it "accumulates multi-source signals over time and preserves source-level reuse" do
    account, profile = build_profile
    store = described_class.new

    post_one = profile.instagram_profile_posts.create!(
      instagram_account: account,
      shortcode: "post_#{SecureRandom.hex(3)}",
      taken_at: 2.days.ago,
      ai_status: "analyzed",
      likes_count: 10,
      comments_count: 2,
      analysis: {
        "topics" => ["travel", "coffee"],
        "hashtags" => ["#trip"],
        "mentions" => ["@sam"],
        "image_description" => "Travel morning with coffee at the airport"
      },
      metadata: {}
    )
    post_two = profile.instagram_profile_posts.create!(
      instagram_account: account,
      shortcode: "post_#{SecureRandom.hex(3)}",
      taken_at: 1.day.ago,
      ai_status: "analyzed",
      likes_count: 16,
      comments_count: 4,
      analysis: {
        "topics" => ["travel", "fitness"],
        "hashtags" => ["#run"],
        "mentions" => ["@alex"],
        "image_description" => "Travel run before dinner"
      },
      metadata: {}
    )
    event = profile.instagram_profile_events.create!(
      kind: "story_analyzed",
      external_id: "story_#{SecureRandom.hex(3)}",
      detected_at: Time.current,
      metadata: {}
    )

    store.ingest_post!(profile: profile, post: post_one, analysis: post_one.analysis, metadata: post_one.metadata)
    store.ingest_post!(profile: profile, post: post_two, analysis: post_two.analysis, metadata: post_two.metadata)
    store.ingest_story!(
      profile: profile,
      event: event,
      intelligence: { "topics" => ["travel"], "transcript" => "airport run and dinner with friends" }
    )
    # Reprocessing unchanged source should no-op.
    store.ingest_post!(profile: profile, post: post_two, analysis: post_two.analysis, metadata: post_two.metadata)

    profile.reload
    signal_store = profile.instagram_profile_behavior_profile.metadata.dig("ai_signal_store")
    topic_rows = Array(signal_store.dig("signals", "topics"))
    travel_row = topic_rows.find { |row| row["value"] == "travel" }

    expect(travel_row["count"]).to eq(3)
    expect(Array(signal_store.dig("signals", "lifestyle")).map { |row| row["value"] }).to include("travel", "fitness")
    expect(Array(signal_store["history"]).count).to eq(3)
    expect(signal_store["processed_sources"].keys.grep(/\Apost:/).size).to eq(2)
  end
end
