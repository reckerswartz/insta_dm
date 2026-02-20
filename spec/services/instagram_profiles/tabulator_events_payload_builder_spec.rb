require "rails_helper"
require "securerandom"
require "stringio"

RSpec.describe InstagramProfiles::TabulatorEventsPayloadBuilder do
  it "serializes event rows and truncates large metadata previews" do
    account = InstagramAccount.create!(username: "acct_#{SecureRandom.hex(4)}")
    profile = account.instagram_profiles.create!(username: "profile_#{SecureRandom.hex(3)}")
    event = profile.instagram_profile_events.create!(
      kind: "story_downloaded",
      external_id: "evt_#{SecureRandom.hex(4)}",
      detected_at: Time.current,
      metadata: {
        "image_url" => "https://cdn.example/story.jpg",
        "payload" => "x" * 1500
      }
    )
    event.media.attach(io: StringIO.new("img"), filename: "story.jpg", content_type: "image/jpeg")

    payload = described_class.new(
      events: [event],
      total: 1,
      pages: 1,
      view_context: instance_double(ActionView::Base)
    ).call

    expect(payload[:last_page]).to eq(1)
    expect(payload[:last_row]).to eq(1)
    row = payload[:data].first
    expect(row[:id]).to eq(event.id)
    expect(row[:kind]).to eq("story_downloaded")
    expect(row[:media_preview_image_url]).to eq("https://cdn.example/story.jpg")
    expect(row[:metadata_json].length).to be <= 1203
    expect(row[:metadata_json]).to end_with("...")
  end
end
