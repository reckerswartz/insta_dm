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
      llm_comment_provider: "local",
      llm_comment_model: "qwen2.5:7b",
      llm_comment_attempts: 1,
      llm_comment_relevance_score: 0.88,
      llm_comment_metadata: {
        "ownership_classification" => { "label" => "self", "summary" => "same profile", "confidence" => 0.93 },
        "generation_policy" => {
          "allow_comment" => true,
          "reason_code" => "verified_context_available",
          "reason" => "Verified context is sufficient.",
          "source" => "verified_story_insight_builder"
        },
        "last_failure" => {
          "reason" => "vision_model_error",
          "source" => "unavailable",
          "error_class" => "StandardError",
          "error_message" => "Vision worker unavailable"
        },
        "generation_inputs" => {
          "selected_topics" => %w[airport outfit],
          "media_topics" => %w[airport outfit],
          "visual_anchors" => %w[airport outfit],
          "context_keywords" => %w[airport outfit travel],
          "content_mode" => "portrait",
          "signal_score" => 5
        },
        "policy_diagnostics" => {
          "rejected_reason_counts" => { "generic_phrase" => 2 },
          "rejected_samples" => [ { "comment" => "Nice post", "reasons" => [ "generic_phrase" ] } ]
        }
      },
      metadata: {
        "upload_time" => "2026-02-19T08:00:00Z",
        "downloaded_at" => "2026-02-19T08:05:00Z",
        "image_url" => "https://cdn.example/story.jpg",
        "story_id" => "story_123",
        "media_bytes" => 321,
        "manual_send_quality_review" => { "status" => "expired_removed", "reason" => "story_unavailable" }
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
    expect(payload[:llm_model_label]).to eq("local / qwen2.5:7b")
    expect(payload[:llm_workflow_status]).to eq("ready")
    expect(payload.dig(:llm_workflow_progress, :summary)).to end_with("/5 completed")
    expect(payload[:llm_policy_allow_comment]).to eq(true)
    expect(payload[:llm_policy_reason_code]).to eq("verified_context_available")
    expect(payload[:llm_failure_reason_code]).to eq("vision_model_error")
    expect(payload[:llm_failure_source]).to eq("unavailable")
    expect(payload[:llm_failure_error_class]).to eq("StandardError")
    expect(payload[:llm_failure_message]).to eq("Vision worker unavailable")
    expect(payload[:manual_send_quality_review]).to include("status" => "expired_removed")
    expect(payload[:story_ownership_label]).to eq("self")
    expect(payload[:llm_input_topics]).to include("airport", "outfit")
    expect(payload[:llm_input_visual_anchors]).to include("airport")
    expect(payload[:llm_input_content_mode]).to eq("portrait")
    expect(payload[:llm_rejected_reason_counts]).to include("generic_phrase" => 2)
  end

  it "does not report failure diagnostics from allow-comment policy metadata alone" do
    _account, profile = create_account_profile
    event = profile.instagram_profile_events.create!(
      kind: "story_downloaded",
      external_id: "evt_#{SecureRandom.hex(4)}",
      detected_at: Time.current,
      occurred_at: Time.current,
      llm_comment_status: "not_requested",
      llm_comment_metadata: {
        "generation_policy" => {
          "allow_comment" => true,
          "reason_code" => "verified_context_available",
          "reason" => "Verified context is sufficient.",
          "source" => "verified_story_insight_builder"
        }
      },
      metadata: { "story_id" => "story_allow_policy_only" }
    )
    event.media.attach(io: File.open(image_fixture_path, "rb"), filename: "story_reference.png", content_type: "image/png")

    payload = described_class.new(event: event).call

    expect(payload[:llm_policy_allow_comment]).to eq(true)
    expect(payload[:llm_policy_reason_code]).to eq("verified_context_available")
    expect(payload[:llm_failure_reason_code]).to be_nil
    expect(payload[:llm_failure_source]).to be_nil
    expect(payload[:llm_failure_message]).to be_nil
    expect(payload[:llm_manual_review_reason]).to be_nil
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

  it "does not enqueue preview generation for videos marked with permanent preview failure" do
    _account, profile = create_account_profile
    event = profile.instagram_profile_events.create!(
      kind: "story_downloaded",
      external_id: "evt_#{SecureRandom.hex(4)}",
      detected_at: Time.current,
      metadata: {
        "preview_image_status" => "failed",
        "preview_image_failure_reason" => "invalid_video_stream"
      }
    )
    event.media.attach(io: File.open(video_fixture_path, "rb"), filename: "story_reference.mp4", content_type: "video/mp4")
    allow(GenerateStoryPreviewImageJob).to receive(:perform_later)

    payload = described_class.new(event: event, preview_enqueue_ttl_seconds: 1).call

    expect(payload[:media_preview_image_url]).to be_nil
    expect(GenerateStoryPreviewImageJob).not_to have_received(:perform_later)
  end

  it "exposes scheduling metadata for queued story comment processing" do
    _account, profile = create_account_profile
    run_at = 2.minutes.from_now
    event = profile.instagram_profile_events.create!(
      kind: "story_downloaded",
      external_id: "evt_#{SecureRandom.hex(4)}",
      detected_at: Time.current,
      occurred_at: Time.current,
      llm_comment_status: "queued",
      llm_blocking_step: "llm_generation",
      llm_pending_reason_code: "queued_llm_generation",
      llm_estimated_ready_at: run_at,
      metadata: {
        "story_id" => "story_queued_1"
      }
    )
    event.media.attach(io: File.open(image_fixture_path, "rb"), filename: "story_reference.png", content_type: "image/png")

    payload = described_class.new(event: event).call

    expect(payload[:llm_queue_state]).to eq("scheduled")
    expect(payload[:llm_queue_name]).to eq("ai_llm_comment_queue")
    expect(payload[:llm_blocking_step]).to eq("llm_generation")
    expect(payload[:llm_pending_reason_code]).to eq("queued_llm_generation")
    expect(payload[:llm_pending_reason]).to include("queued behind")
    expect(payload[:llm_schedule_service]).to eq("GenerateLlmCommentJob")
    expect(payload[:llm_schedule_run_at]).to be_present
    expect(Time.zone.parse(payload[:llm_schedule_run_at])).to be_within(1.second).of(run_at)
  end

  it "treats not_requested llm status as ready workflow state" do
    _account, profile = create_account_profile
    event = profile.instagram_profile_events.create!(
      kind: "story_downloaded",
      external_id: "evt_#{SecureRandom.hex(4)}",
      detected_at: Time.current,
      occurred_at: Time.current,
      llm_comment_status: "not_requested",
      metadata: { "story_id" => "story_not_requested" }
    )
    event.media.attach(io: File.open(image_fixture_path, "rb"), filename: "story_reference.png", content_type: "image/png")

    payload = described_class.new(event: event).call

    expect(payload[:llm_workflow_status]).to eq("ready")
  end

  it "removes wrapping quotes from generated and ranked comments" do
    _account, profile = create_account_profile
    event = profile.instagram_profile_events.create!(
      kind: "story_downloaded",
      external_id: "evt_#{SecureRandom.hex(4)}",
      detected_at: Time.current,
      occurred_at: Time.current,
      llm_generated_comment: "\"Love this moment\"",
      llm_comment_status: "completed",
      llm_comment_metadata: {
        "ranked_candidates" => [
          { "comment" => "\"Such a clean shot\"", "score" => 0.93 },
          { "comment" => "Already clean", "score" => 0.81 }
        ]
      }
    )
    event.media.attach(io: File.open(image_fixture_path, "rb"), filename: "story_reference.png", content_type: "image/png")

    payload = described_class.new(event: event).call

    expect(payload[:llm_generated_comment]).to eq("Love this moment")
    expect(payload[:llm_ranked_suggestions]).to include("Such a clean shot", "Already clean")
    expect(payload[:llm_ranked_candidates].first["comment"]).to eq("Such a clean shot")
  end

  it "includes story analysis queue status and failure details" do
    _account, profile = create_account_profile
    story_id = "story_#{SecureRandom.hex(4)}"
    event = profile.instagram_profile_events.create!(
      kind: "story_downloaded",
      external_id: "evt_#{SecureRandom.hex(4)}",
      detected_at: Time.current,
      occurred_at: Time.current,
      metadata: { "story_id" => story_id }
    )
    event.media.attach(io: File.open(image_fixture_path, "rb"), filename: "story_reference.png", content_type: "image/png")

    profile.record_event!(
      kind: "story_analysis_queued",
      external_id: "story_analysis_queued:#{story_id}",
      metadata: {
        "story_id" => story_id,
        "status" => "failed",
        "failure_reason" => "analysis_error",
        "error_message" => "Vision worker unavailable",
        "status_updated_at" => Time.current.iso8601(3)
      }
    )

    payload = described_class.new(event: event).call

    expect(payload[:analysis_status]).to eq("failed")
    expect(payload[:analysis_failure_reason]).to eq("analysis_error")
    expect(payload[:analysis_error_message]).to eq("Vision worker unavailable")
    expect(payload[:analysis_updated_at]).to be_present
  end
end
