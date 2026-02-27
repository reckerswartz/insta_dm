require "rails_helper"
require "securerandom"

RSpec.describe Ops::LocalStoryIntelligenceBackfill do
  let(:image_fixture_path) { Rails.root.join("spec/fixtures/files/story_archive/story_reference.png") }
  let(:video_fixture_path) { Rails.root.join("spec/fixtures/files/story_archive/story_reference.mp4") }

  it "requeues only pending video story events" do
    account = InstagramAccount.create!(username: "acct_#{SecureRandom.hex(4)}")
    profile = InstagramProfile.create!(instagram_account: account, username: "profile_#{SecureRandom.hex(3)}")

    video_a = create_story_event(profile: profile, external_id: "evt_video_a", llm_comment_status: "not_requested")
    video_a.media.attach(io: File.open(video_fixture_path, "rb"), filename: "story_a.mp4", content_type: "video/mp4")

    image = create_story_event(profile: profile, external_id: "evt_image", llm_comment_status: "not_requested")
    image.media.attach(io: File.open(image_fixture_path, "rb"), filename: "story_image.png", content_type: "image/png")

    video_with_comment = create_story_event(
      profile: profile,
      external_id: "evt_video_with_comment",
      llm_comment_status: "not_requested",
      llm_generated_comment: "already there"
    )
    video_with_comment.media.attach(io: File.open(video_fixture_path, "rb"), filename: "story_comment.mp4", content_type: "video/mp4")

    video_b = create_story_event(profile: profile, external_id: "evt_video_b", llm_comment_status: "not_requested")
    video_b.media.attach(io: File.open(video_fixture_path, "rb"), filename: "story_b.mp4", content_type: "video/mp4")

    no_media = create_story_event(profile: profile, external_id: "evt_no_media", llm_comment_status: "not_requested")
    expect(no_media.media).not_to be_attached

    allow(GenerateLlmCommentJob).to receive(:perform_later) do |**args|
      instance_double(ActiveJob::Base, job_id: "job-#{args[:instagram_profile_event_id]}")
    end

    result = described_class.new(account_id: account.id, limit: 20, enqueue_comments: false).requeue_pending_video_generation!

    expect(result).to include(
      scanned: 4,
      queued: 2,
      skipped_non_video: 1,
      skipped_has_comment: 1,
      skipped_in_progress: 0
    )

    expect(video_a.reload.llm_comment_status).to eq("queued")
    expect(video_a.llm_comment_job_id).to be_present
    expect(video_b.reload.llm_comment_status).to eq("queued")
    expect(video_b.llm_comment_job_id).to be_present
    expect(image.reload.llm_comment_status).to eq("not_requested")

    expect(GenerateLlmCommentJob).to have_received(:perform_later).with(
      hash_including(
        instagram_profile_event_id: video_a.id,
        provider: "local",
        requested_by: "local_story_video_requeue"
      )
    )
    expect(GenerateLlmCommentJob).to have_received(:perform_later).with(
      hash_including(
        instagram_profile_event_id: video_b.id,
        provider: "local",
        requested_by: "local_story_video_requeue"
      )
    )
  end

  it "honors the provided scan limit" do
    account = InstagramAccount.create!(username: "acct_#{SecureRandom.hex(4)}")
    profile = InstagramProfile.create!(instagram_account: account, username: "profile_#{SecureRandom.hex(3)}")

    event_one = create_story_event(profile: profile, external_id: "evt_limit_1", llm_comment_status: "not_requested")
    event_one.media.attach(io: File.open(video_fixture_path, "rb"), filename: "limit_1.mp4", content_type: "video/mp4")

    event_two = create_story_event(profile: profile, external_id: "evt_limit_2", llm_comment_status: "not_requested")
    event_two.media.attach(io: File.open(video_fixture_path, "rb"), filename: "limit_2.mp4", content_type: "video/mp4")

    allow(GenerateLlmCommentJob).to receive(:perform_later) do |**args|
      instance_double(ActiveJob::Base, job_id: "job-#{args[:instagram_profile_event_id]}")
    end

    result = described_class.new(account_id: account.id, limit: 1, enqueue_comments: false).requeue_pending_video_generation!

    expect(result[:scanned]).to eq(1)
    expect(result[:queued]).to eq(1)
    expect([ event_one.reload.llm_comment_status, event_two.reload.llm_comment_status ]).to include("queued")
  end

  def create_story_event(profile:, external_id:, llm_comment_status:, llm_generated_comment: nil)
    profile.instagram_profile_events.create!(
      kind: "story_downloaded",
      external_id: external_id,
      detected_at: Time.current,
      occurred_at: Time.current,
      metadata: { "story_id" => "story_#{external_id}" },
      llm_comment_status: llm_comment_status,
      llm_generated_comment: llm_generated_comment
    )
  end
end
