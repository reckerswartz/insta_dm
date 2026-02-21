require "rails_helper"
require "securerandom"

RSpec.describe StoryIntelligence::PayloadBuilder do
  def build_video_event
    account = InstagramAccount.create!(username: "acct_#{SecureRandom.hex(4)}")
    profile = account.instagram_profiles.create!(username: "story_profile_#{SecureRandom.hex(4)}")
    event = profile.record_event!(
      kind: "story_downloaded",
      external_id: "story_downloaded:#{SecureRandom.hex(6)}",
      metadata: {
        "story_id" => SecureRandom.hex(8),
        "media_type" => "video"
      }
    )
    event.media.attach(
      io: StringIO.new("video-bytes"),
      filename: "story.mp4",
      content_type: "video/mp4"
    )
    event
  end

  it "hydrates video payload from lightweight video context extraction" do
    event = build_video_event
    extractor = instance_double(PostVideoContextExtractionService)
    allow(PostVideoContextExtractionService).to receive(:new).and_return(extractor)
    allow(extractor).to receive(:extract).and_return(
      {
        skipped: false,
        processing_mode: "dynamic_video",
        semantic_route: "video",
        static: false,
        duration_seconds: 12.4,
        has_audio: true,
        transcript: "Morning run soundtrack",
        topics: [ "run", "morning" ],
        objects: [ "person", "shoe" ],
        object_detections: [ { label: "person", confidence: 0.92 } ],
        scenes: [ { type: "outdoor", timestamp: 1.2 } ],
        hashtags: [ "#run" ],
        mentions: [ "@coach" ],
        profile_handles: [ "coach.profile" ],
        ocr_text: "@coach #run",
        ocr_blocks: [ { text: "@coach #run", confidence: 0.9 } ],
        metadata: {
          frame_change_detection: { sampled_frames: 3 }
        }
      }
    )

    payload = described_class.new(event: event).build_payload

    expect(payload[:source]).to eq("live_local_video_context")
    expect(payload[:transcript]).to eq("Morning run soundtrack")
    expect(payload[:objects]).to include("person", "shoe")
    expect(payload[:topics]).to include("run", "morning")
    expect(payload[:hashtags]).to include("#run")
    expect(payload[:mentions]).to include("@coach")
    expect(payload[:profile_handles]).to include("coach.profile")
    expect(payload[:object_detections]).not_to be_empty
    expect(Array(payload[:processing_log])).not_to be_empty
  end

  it "marks payload unavailable when video extraction returns no usable context" do
    event = build_video_event
    extractor = instance_double(PostVideoContextExtractionService)
    allow(PostVideoContextExtractionService).to receive(:new).and_return(extractor)
    allow(extractor).to receive(:extract).and_return(
      {
        skipped: true,
        processing_mode: "dynamic_video",
        transcript: nil,
        topics: [],
        objects: [],
        object_detections: [],
        scenes: [],
        hashtags: [],
        mentions: [],
        profile_handles: [],
        ocr_text: nil,
        ocr_blocks: [],
        metadata: {
          reason: "video_too_large_for_context_extraction"
        }
      }
    )

    payload = described_class.new(event: event).build_payload

    expect(payload[:source]).to eq("unavailable")
    expect(payload[:reason]).to eq("video_too_large_for_context_extraction")
  end
end
