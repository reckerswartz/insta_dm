require "rails_helper"
require "securerandom"
require "stringio"

RSpec.describe Ops::AuditLogBuilder do
  it "surfaces explicit skip reason and media references for skipped story events" do
    account = InstagramAccount.create!(username: "acct_#{SecureRandom.hex(4)}")
    profile = InstagramProfile.create!(instagram_account: account, username: "profile_#{SecureRandom.hex(3)}")

    profile.instagram_profile_events.create!(
      kind: "story_sync_failed",
      external_id: "evt_#{SecureRandom.hex(4)}",
      detected_at: Time.current,
      metadata: {
        "reason" => "api_story_media_unavailable",
        "story_ref" => "sample_user:123",
        "story_url" => "https://www.instagram.com/stories/sample_user/123/",
        "api_failure_status" => 429,
        "api_failure_endpoint" => "web_profile_info",
        "retryable" => true
      }
    )

    with_media = profile.instagram_profile_events.create!(
      kind: "story_reply_skipped",
      external_id: "evt_#{SecureRandom.hex(4)}",
      detected_at: Time.current + 1.second,
      metadata: {
        "reason" => "duplicate_story_already_downloaded",
        "media_url" => "https://cdn.example/story.jpg"
      }
    )
    with_media.media.attach(io: StringIO.new("img"), filename: "story.jpg", content_type: "image/jpeg")

    rows = described_class.for_account(instagram_account: account, limit: 20)
    failed = rows.find { |row| row[:kind] == "story_sync_failed" }
    attached = rows.find { |row| row[:kind] == "story_reply_skipped" && row[:profile_id] == profile.id }

    expect(failed[:skip_event]).to eq(true)
    expect(failed[:skip_reason]).to eq("api_story_media_unavailable")
    expect(failed[:detail]).to include("Failure reason: api_story_media_unavailable")
    expect(failed[:media_url]).to eq("https://www.instagram.com/stories/sample_user/123/")
    expect(failed[:media_reference_url]).to eq("https://www.instagram.com/stories/sample_user/123/")
    expect(failed[:media_modal_supported]).to eq(false)
    expect(failed[:media_download_url]).to eq("https://www.instagram.com/stories/sample_user/123/")

    expect(attached[:media_attached]).to eq(true)
    expect(attached[:media_modal_supported]).to eq(true)
    expect(attached[:media_url]).to include("/rails/active_storage/")
    expect(attached[:media_download_url]).to include("/rails/active_storage/")
  end
end
