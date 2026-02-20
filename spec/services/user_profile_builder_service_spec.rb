require "rails_helper"
require "securerandom"

RSpec.describe UserProfileBuilderService do
  it "returns nil when profile has no processed stories" do
    account = InstagramAccount.create!(username: "acct_#{SecureRandom.hex(4)}")
    profile = account.instagram_profiles.create!(username: "profile_#{SecureRandom.hex(4)}")
    account.instagram_stories.create!(
      instagram_profile: profile,
      story_id: "story_#{SecureRandom.hex(4)}",
      processed: false,
      processing_status: "pending"
    )

    result = described_class.new.refresh!(profile: profile)

    expect(result).to be_nil
  end

  it "builds a behavior profile using stories, faces, and preserved summary keys" do
    account = InstagramAccount.create!(username: "acct_#{SecureRandom.hex(4)}")
    profile = account.instagram_profiles.create!(username: "profile_#{SecureRandom.hex(4)}")

    existing_record = InstagramProfileBehaviorProfile.create!(
      instagram_profile: profile,
      activity_score: 0.01,
      behavioral_summary: {
        "face_identity_profile" => { "primary" => "owner" },
        "related_individuals" => [ { "username" => "friend_1" } ],
        "known_username_matches" => [ "friend_1" ]
      },
      metadata: { "seeded" => true }
    )

    friend_person = profile.instagram_story_people.create!(
      instagram_account: account,
      role: "secondary_person",
      label: "Friend"
    )
    primary_person = profile.instagram_story_people.create!(
      instagram_account: account,
      role: "primary_user",
      label: "Owner"
    )

    story_one = account.instagram_stories.create!(
      instagram_profile: profile,
      story_id: "story_#{SecureRandom.hex(4)}",
      processed: true,
      processing_status: "processed",
      taken_at: Time.utc(2026, 2, 19, 9, 30, 0),
      metadata: {
        "location_tags" => [ "NYC" ],
        "content_signals" => [ "food", "lifestyle" ],
        "content_understanding" => {
          "topics" => [ "coffee", "brunch" ],
          "hashtags" => [ "#coffee", "#brunch" ],
          "sentiment" => "positive"
        }
      }
    )
    story_two = account.instagram_stories.create!(
      instagram_profile: profile,
      story_id: "story_#{SecureRandom.hex(4)}",
      processed: true,
      processing_status: "processed",
      taken_at: Time.utc(2026, 2, 19, 10, 45, 0),
      metadata: {
        "location_tags" => [ "NYC", "Paris" ],
        "content_signals" => [ "travel" ],
        "content_understanding" => {
          "topics" => [ "city_walk" ],
          "hashtags" => [ "#travel" ],
          "sentiment" => "positive"
        }
      }
    )

    InstagramStoryFace.create!(instagram_story: story_one, instagram_story_person: friend_person, role: "secondary_person")
    InstagramStoryFace.create!(instagram_story: story_two, instagram_story_person: friend_person, role: "secondary_person")
    InstagramStoryFace.create!(instagram_story: story_two, instagram_story_person: primary_person, role: "primary_user")

    profile_post = profile.instagram_profile_posts.create!(
      instagram_account: account,
      shortcode: "profile_post_#{SecureRandom.hex(4)}",
      taken_at: Time.current
    )
    InstagramPostFace.create!(
      instagram_profile_post: profile_post,
      instagram_story_person: friend_person,
      role: "secondary_person"
    )

    record = described_class.new.refresh!(profile: profile)
    record.reload

    expect(record.id).to eq(existing_record.id)
    expect(record.activity_score).to eq(0.1)
    expect(record.metadata["stories_processed"]).to eq(2)
    expect(record.metadata["post_faces_processed"]).to eq(1)
    expect(record.metadata["refreshed_at"]).to be_present

    summary = record.behavioral_summary
    expect(summary.dig("posting_time_pattern", "hour_histogram")).to include("9" => 1, "10" => 1)
    expect(summary.dig("posting_time_pattern", "weekday_histogram").values.sum).to eq(2)
    expect(summary["common_locations"]).to eq({ "NYC" => 2, "Paris" => 1 })
    expect(summary["content_categories"]).to include("food" => 1, "travel" => 1)
    expect(summary["topic_clusters"]).to include("coffee" => 1, "city_walk" => 1)
    expect(summary["top_hashtags"]).to include("#coffee" => 1, "#travel" => 1)
    expect(summary["sentiment_trend"]).to eq({ "positive" => 2 })

    secondary_people = Array(summary["frequent_secondary_persons"])
    expect(secondary_people.map { |row| row["person_id"] }).to eq([ friend_person.id ])
    expect(secondary_people.first["appearances"]).to eq(3)

    expect(summary["face_identity_profile"]).to eq({ "primary" => "owner" })
    expect(summary["related_individuals"]).to eq([ { "username" => "friend_1" } ])
    expect(summary["known_username_matches"]).to eq([ "friend_1" ])
  end
end
