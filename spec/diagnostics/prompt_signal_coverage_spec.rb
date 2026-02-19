require "rails_helper"
require "securerandom"

RSpec.describe "Prompt Signal Coverage Diagnostics", :diagnostic do
  it "extracts core story-intelligence prompt signals from recent profile events" do
    account = InstagramAccount.create!(username: "signal_diag_#{SecureRandom.hex(4)}")
    profile = account.instagram_profiles.create!(username: "signal_profile_#{SecureRandom.hex(4)}")

    3.times do |idx|
      event = profile.instagram_profile_events.create!(
        kind: "story_downloaded",
        external_id: "diag_evt_#{idx}_#{SecureRandom.hex(3)}",
        detected_at: Time.current - idx.minutes,
        occurred_at: Time.current - idx.minutes,
        metadata: {
          "local_story_intelligence" => {
            "ocr_text" => idx.zero? ? "SALE 20%" : "",
            "objects" => (idx.even? ? ["shoe", "logo"] : []),
            "mentions" => (idx == 1 ? ["@brand"] : []),
            "profile_handles" => (idx == 2 ? ["@owner"] : []),
            "face_count" => idx + 1,
          },
          "validated_story_insights" => {
            "verified_story_facts" => {
              "hashtags" => ["#offer"],
              "identity_verification" => { "owner_likelihood" => "high", "confidence" => 0.87 },
            },
            "generation_policy" => { "allow_comment" => true },
          },
        },
      )

      event.media.attach(
        io: StringIO.new("signal-media-#{idx}"),
        filename: "signal_#{idx}.jpg",
        content_type: "image/jpeg",
      )
    end

    snapshots = profile.instagram_profile_events.reorder(detected_at: :desc).limit(10).map do |event|
      metadata = event.metadata.is_a?(Hash) ? event.metadata : {}
      local = metadata["local_story_intelligence"].is_a?(Hash) ? metadata["local_story_intelligence"] : {}
      validated = metadata["validated_story_insights"].is_a?(Hash) ? metadata["validated_story_insights"] : {}
      verified = validated["verified_story_facts"].is_a?(Hash) ? validated["verified_story_facts"] : {}
      policy = validated["generation_policy"].is_a?(Hash) ? validated["generation_policy"] : {}

      {
        ocr_text_present: verified["ocr_text"].to_s.present? || local["ocr_text"].to_s.present?,
        objects_count: Array(verified["objects"]).presence&.size || Array(local["objects"]).size,
        mentions_count: Array(verified["mentions"]).presence&.size || Array(local["mentions"]).size,
        profile_handles_count: Array(verified["profile_handles"]).presence&.size || Array(local["profile_handles"]).size,
        faces_count: (verified["face_count"] || local["face_count"]).to_i,
        owner_likelihood: verified.dig("identity_verification", "owner_likelihood"),
        allow_comment: policy["allow_comment"],
      }
    end

    expect(snapshots.size).to eq(3)
    expect(snapshots.count { |row| row[:ocr_text_present] }).to be >= 1
    expect(snapshots.count { |row| row[:objects_count].to_i > 0 }).to be >= 1
    expect(snapshots.count { |row| row[:mentions_count].to_i > 0 }).to be >= 1
    expect(snapshots.count { |row| row[:profile_handles_count].to_i > 0 }).to be >= 1
    expect(snapshots.count { |row| row[:faces_count].to_i > 0 }).to eq(3)
    expect(snapshots.count { |row| row[:owner_likelihood].to_s == "high" }).to eq(3)
    expect(snapshots.count { |row| row[:allow_comment] == true }).to eq(3)
  end
end
