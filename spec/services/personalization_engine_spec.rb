require "rails_helper"
require "securerandom"

RSpec.describe PersonalizationEngine do
  it "builds persona attributes from profile behavior summary" do
    account = InstagramAccount.create!(username: "acct_#{SecureRandom.hex(4)}")
    profile = account.instagram_profiles.create!(username: "profile_#{SecureRandom.hex(4)}")
    profile.create_instagram_profile_behavior_profile!(
      behavioral_summary: {
        "content_categories" => {
          "travel" => 10,
          "fitness" => 8,
          "coffee" => 5
        },
        "sentiment_trend" => {
          "positive" => 4,
          "neutral" => 1
        },
        "top_hashtags" => {
          "#trip" => 8,
          "#workout" => 7,
          "#coffee" => 6
        },
        "frequent_secondary_persons" => [
          { "person_id" => 1 },
          { "person_id" => 2 },
          { "person_id" => 3 }
        ]
      }
    )

    persona = described_class.new.build(profile: profile)

    expect(persona).to include(
      tone: "optimistic",
      interests: %w[travel fitness coffee],
      emoji_style: "moderate",
      engagement_style: "community"
    )
  end

  it "returns default profile when behavior lookup raises" do
    profile = instance_double(InstagramProfile)
    allow(profile).to receive(:instagram_profile_behavior_profile).and_raise("boom")

    persona = described_class.new.build(profile: profile)

    expect(persona).to eq(described_class::DEFAULT_PROFILE)
  end
end
