require "rails_helper"
require "securerandom"
require "stringio"

RSpec.describe InstagramAccounts::StoryArchiveItemSerializer do
  let(:image_fixture_path) { Rails.root.join("spec/fixtures/files/story_archive/story_reference.png") }
  let(:video_fixture_path) { Rails.root.join("spec/fixtures/files/story_archive/story_reference.mp4") }

  def create_account_profile
    account = InstagramAccount.create!(username: "acct_#{SecureRandom.hex(4)}")
    profile = InstagramProfile.create!(
      instagram_account: account,
      username: "profile_#{SecureRandom.hex(3)}",
      display_name: "Story Profile"
    )
    [account, profile]
  end

  it "serializes story archive event payload with media and llm metadata" do
    _account, profile = create_account_profile
    event = profile.instagram_profile_events.create!(
      kind: "story_downloaded",
      external_id: "evt_#{SecureRandom.hex(4)}",
      detected_at: Time.current,
      occurred_at: Time.current,
      llm_generated_comment: "Looks great!",
      llm_comment_status: "completed",
      llm_comment_attempts: 1,
      llm_comment_relevance_score: 0.88,
      llm_comment_metadata: {
        "ownership_classification" => { "label" => "self", "summary" => "same profile", "confidence" => 0.93 }
      },
      metadata: {
        "upload_time" => "2026-02-19T08:00:00Z",
        "downloaded_at" => "2026-02-19T08:05:00Z",
        "image_url" => "https://cdn.example/story.jpg",
        "story_id" => "story_123",
        "media_bytes" => 321
      }
    )
    event.media.attach(io: File.open(image_fixture_path, "rb"), filename: "story_reference.png", content_type: "image/png")

    payload = described_class.new(event: event).call

    expect(payload[:id]).to eq(event.id)
    expect(payload[:profile_id]).to eq(profile.id)
    expect(payload[:profile_username]).to eq(profile.username)
    expect(payload[:story_id]).to eq("story_123")
    expect(payload[:media_preview_image_url]).to eq("https://cdn.example/story.jpg")
    expect(payload[:video_static_frame_only]).to eq(false)
    expect(payload[:media_bytes]).to eq(321)
    expect(payload[:llm_comment_status]).to eq("completed")
    expect(payload[:story_ownership_label]).to eq("self")
  end

  it "enqueues preview generation for video media when no preview URL is available" do
    _account, profile = create_account_profile
    event = profile.instagram_profile_events.create!(
      kind: "story_downloaded",
      external_id: "evt_#{SecureRandom.hex(4)}",
      detected_at: Time.current,
      metadata: {}
    )
    event.media.attach(io: File.open(video_fixture_path, "rb"), filename: "story_reference.mp4", content_type: "video/mp4")
    allow(GenerateStoryPreviewImageJob).to receive(:perform_later)

    payload = described_class.new(event: event, preview_enqueue_ttl_seconds: 1).call

    expect(payload[:media_preview_image_url]).to be_nil
    expect(GenerateStoryPreviewImageJob).to have_received(:perform_later).with(instagram_profile_event_id: event.id)
  end
end
