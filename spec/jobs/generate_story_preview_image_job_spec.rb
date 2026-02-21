require "rails_helper"
require "securerandom"
require "stringio"

RSpec.describe GenerateStoryPreviewImageJob do
  def build_story_video_event
    account = InstagramAccount.create!(username: "acct_#{SecureRandom.hex(4)}")
    profile = account.instagram_profiles.create!(username: "story_user_#{SecureRandom.hex(3)}")
    event = profile.record_event!(
      kind: "story_downloaded",
      external_id: "story_downloaded:#{SecureRandom.hex(6)}",
      metadata: { story_id: "preview_story_1", media_type: "video" }
    )
    event.media.attach(
      io: StringIO.new("....ftypisom....video".b),
      filename: "story.mp4",
      content_type: "video/mp4"
    )
    event
  end

  it "attaches preview image from remote story payload in background" do
    event = build_story_video_event

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

  it "marks malformed video streams as failed without ActiveStorage fallback" do
    event = build_story_video_event
    thumb_service = instance_double(VideoThumbnailService)
    job = described_class.new

    allow(job).to receive(:download_preview_image).and_return(nil)
    allow(VideoThumbnailService).to receive(:new).and_return(thumb_service)
    allow(thumb_service).to receive(:extract_first_frame).and_return(
      {
        ok: false,
        image_bytes: nil,
        content_type: nil,
        filename: nil,
        metadata: {
          source: "ffmpeg",
          reason: "ffmpeg_extract_failed",
          stderr: "Error opening input files: Invalid data found when processing input"
        }
      }
    )
    expect(job).not_to receive(:attach_preview_via_active_storage!)

    job.perform(instagram_profile_event_id: event.id)

    event.reload
    expect(event.preview_image).not_to be_attached
    expect(event.metadata["preview_image_status"]).to eq("failed")
    expect(event.metadata["preview_image_failure_reason"]).to eq("invalid_video_stream")
    expect(event.metadata["preview_image_failure_detail"]).to include("Invalid data found")
  end

  it "still tries ActiveStorage fallback for non-permanent ffmpeg extraction errors" do
    event = build_story_video_event
    thumb_service = instance_double(VideoThumbnailService)
    job = described_class.new

    allow(job).to receive(:download_preview_image).and_return(nil)
    allow(VideoThumbnailService).to receive(:new).and_return(thumb_service)
    allow(thumb_service).to receive(:extract_first_frame).and_return(
      {
        ok: false,
        image_bytes: nil,
        content_type: nil,
        filename: nil,
        metadata: {
          source: "ffmpeg",
          reason: "ffmpeg_extract_failed",
          stderr: "Resource temporarily unavailable"
        }
      }
    )
    expect(job).to receive(:attach_preview_via_active_storage!).with(event: event).and_return(true)

    job.perform(instagram_profile_event_id: event.id)
  end
end
