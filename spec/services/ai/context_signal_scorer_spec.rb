require "rails_helper"
require "securerandom"

RSpec.describe Ai::ContextSignalScorer do
  def build_profile
    account = InstagramAccount.create!(username: "acct_#{SecureRandom.hex(4)}")
    profile = account.instagram_profiles.create!(username: "profile_#{SecureRandom.hex(4)}")
    [account, profile]
  end

  it "prioritizes accumulated signals that overlap with current content" do
    account, profile = build_profile

    profile.create_instagram_profile_behavior_profile!(
      behavioral_summary: {
        "content_categories" => { "travel" => 7, "fitness" => 3 },
        "topic_clusters" => { "beach" => 4 },
        "top_hashtags" => { "#trip" => 5 },
        "sentiment_trend" => { "positive" => 3 }
      },
      metadata: {
        "ai_signal_store" => {
          "signals" => {
            "topics" => [
              { "value" => "travel", "count" => 4, "last_seen_at" => 2.hours.ago.iso8601 },
              { "value" => "coffee", "count" => 2, "last_seen_at" => 2.days.ago.iso8601 }
            ]
          }
        }
      }
    )

    profile.instagram_profile_events.create!(
      kind: "post_comment_sent",
      external_id: "sent_#{SecureRandom.hex(3)}",
      detected_at: Time.current,
      metadata: { "comment_text" => "Love this travel vibe" }
    )
    profile.instagram_profile_events.create!(
      kind: "story_analyzed",
      external_id: "story_#{SecureRandom.hex(3)}",
      detected_at: Time.current,
      llm_generated_comment: "Love this travel vibe right here"
    )

    result = described_class.new(profile: profile, channel: "post").build(
      current_topics: ["travel", "sunset"],
      image_description: "Travel sunset at the beach",
      caption: "Trip day"
    )

    values = result[:prioritized_signals].map { |row| row[:value] }
    expect(values).to include("travel")
    expect(result[:context_keywords]).to include("travel")
    expect(result.dig(:style_profile, :tone)).to eq("optimistic")
    expect(result.dig(:engagement_memory, :recent_generated_comments)).to include("Love this travel vibe")
    expect(result.dig(:engagement_memory, :recent_openers)).not_to be_empty
    expect(result.dig(:engagement_memory, :relationship_familiarity)).to eq("neutral")
  end
end
