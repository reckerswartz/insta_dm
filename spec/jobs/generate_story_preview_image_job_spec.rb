require "rails_helper"
require "securerandom"

RSpec.describe GenerateStoryPreviewImageJob do
  it "attaches preview image from remote story payload in background" do
    account = InstagramAccount.create!(username: "acct_#{SecureRandom.hex(4)}")
    profile = account.instagram_profiles.create!(username: "story_user_#{SecureRandom.hex(3)}")
    event = profile.record_event!(
      kind: "story_downloaded",
      external_id: "story_downloaded:#{SecureRandom.hex(6)}",
      metadata: { story_id: "preview_story_1", media_type: "video" }
    )
    event.media.attach(
      io: StringIO.new("video-bytes"),
      filename: "story.mp4",
      content_type: "video/mp4"
    )

    allow_any_instance_of(described_class).to receive(:download_preview_image).and_return(
      {
        bytes: "jpeg-bytes",
        content_type: "image/jpeg",
        filename: "preview.jpg"
      }
    )

    described_class.perform_now(
      instagram_profile_event_id: event.id,
      story_payload: { image_url: "https://cdn.example.com/story_preview.jpg" },
      user_agent: "spec-user-agent"
    )

    event.reload
    expect(event.preview_image).to be_attached
    expect(event.metadata["preview_image_status"]).to eq("attached")
    expect(event.metadata["preview_image_source"]).to eq("remote_image_url")
  end
end
