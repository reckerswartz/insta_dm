require "rails_helper"
require "securerandom"

RSpec.describe InstagramAccounts::LlmCommentRequestService do
  let(:account) { InstagramAccount.create!(username: "acct_#{SecureRandom.hex(4)}") }
  let(:profile) { InstagramProfile.create!(instagram_account: account, username: "profile_#{SecureRandom.hex(3)}") }
  let(:queue_inspector) { instance_double(InstagramAccounts::LlmQueueInspector, queue_size: 2, stale_comment_job?: false) }

  it "returns not_found when the event does not belong to the account" do
    other_account = InstagramAccount.create!(username: "acct_#{SecureRandom.hex(4)}")
    other_profile = InstagramProfile.create!(instagram_account: other_account, username: "profile_#{SecureRandom.hex(3)}")
    event = create_story_event(profile: other_profile)

    result = described_class.new(
      account: account,
      event_id: event.id,
      provider: "local",
      model: nil,
      status_only: false,
      queue_inspector: queue_inspector
    ).call

    expect(result.status).to eq(:not_found)
    expect(result.payload[:error]).to eq("Event not found or not accessible")
  end

  it "returns completed payload for already generated comments and normalizes status" do
    event = create_story_event(
      profile: profile,
      llm_generated_comment: "Already generated",
      llm_comment_status: "running"
    )

    result = described_class.new(
      account: account,
      event_id: event.id,
      provider: "local",
      model: nil,
      status_only: false,
      queue_inspector: queue_inspector
    ).call

    expect(result.status).to eq(:ok)
    expect(result.payload).to include(success: true, status: "completed", event_id: event.id)
    expect(event.reload.llm_comment_status).to eq("completed")
  end

  it "re-queues generation when force is true for an already completed comment" do
    event = create_story_event(
      profile: profile,
      llm_generated_comment: "Old generated comment",
      llm_comment_status: "completed",
      llm_comment_generated_at: 1.hour.ago,
      llm_comment_metadata: {
        "parallel_pipeline" => {
          "run_id" => "run-keep-1",
          "status" => "failed",
          "steps" => {
            "ocr_analysis" => { "status" => "succeeded" }
          }
        }
      }
    )
    job = instance_double(ActiveJob::Base, job_id: "job-force-1")
    allow(GenerateLlmCommentJob).to receive(:perform_later).and_return(job)

    result = described_class.new(
      account: account,
      event_id: event.id,
      provider: "local",
      model: nil,
      status_only: false,
      force: true,
      queue_inspector: queue_inspector
    ).call

    expect(result.status).to eq(:accepted)
    expect(result.payload).to include(success: true, status: "queued", event_id: event.id, job_id: "job-force-1", forced: true)
    event.reload
    expect(event.llm_comment_status).to eq("queued")
    expect(event.llm_generated_comment).to be_nil
    expect(event.llm_comment_generated_at).to be_nil
    expect(event.llm_comment_metadata.dig("parallel_pipeline", "run_id")).to eq("run-keep-1")
  end

  it "supports regenerate_all and clears reusable pipeline metadata" do
    event = create_story_event(
      profile: profile,
      llm_generated_comment: "Old generated comment",
      llm_comment_status: "completed",
      llm_comment_generated_at: 1.hour.ago,
      llm_comment_metadata: {
        "parallel_pipeline" => {
          "run_id" => "run-clear-1",
          "status" => "failed",
          "steps" => {
            "ocr_analysis" => { "status" => "succeeded" }
          }
        }
      }
    )
    job = instance_double(ActiveJob::Base, job_id: "job-force-2")
    allow(GenerateLlmCommentJob).to receive(:perform_later).and_return(job)

    result = described_class.new(
      account: account,
      event_id: event.id,
      provider: "local",
      model: nil,
      status_only: false,
      regenerate_all: true,
      queue_inspector: queue_inspector
    ).call

    expect(result.status).to eq(:accepted)
    expect(result.payload[:regenerate_all]).to eq(true)
    expect(GenerateLlmCommentJob).to have_received(:perform_later).with(
      instagram_profile_event_id: event.id,
      provider: "local",
      model: nil,
      requested_by: "dashboard_manual_request",
      regenerate_all: true
    )
    expect(event.reload.llm_comment_metadata["parallel_pipeline"]).to be_nil
  end

  it "returns status-only payload without enqueuing when requested" do
    event = create_story_event(profile: profile)
    allow(GenerateLlmCommentJob).to receive(:perform_later)

    result = described_class.new(
      account: account,
      event_id: event.id,
      provider: "local",
      model: nil,
      status_only: true,
      queue_inspector: queue_inspector
    ).call

    expect(result.status).to eq(:ok)
    expect(result.payload).to include(success: true, status: "not_requested", event_id: event.id, queue_size: 2)
    expect(GenerateLlmCommentJob).not_to have_received(:perform_later)
  end

  it "merges local extraction stages with llm stages for status responses" do
    event = create_story_event(
      profile: profile,
      llm_comment_status: "running",
      metadata: {
        "local_story_intelligence" => {
          "processing_stages" => {
            "video_analysis" => { "label" => "Video Analysis", "state" => "completed", "progress" => 100 }
          },
          "processing_log" => [
            { "stage" => "video_analysis", "state" => "completed", "message" => "Video analysis completed.", "at" => 2.minutes.ago.iso8601 }
          ]
        }
      },
      llm_comment_metadata: {
        "processing_stages" => {
          "llm_generation" => { "label" => "Generating Comments", "state" => "running", "progress" => 68 }
        },
        "processing_log" => [
          { "stage" => "llm_generation", "state" => "running", "message" => "Generating comments.", "at" => Time.current.iso8601 }
        ]
      }
    )

    result = described_class.new(
      account: account,
      event_id: event.id,
      provider: "local",
      model: nil,
      status_only: true,
      queue_inspector: queue_inspector
    ).call

    expect(result.status).to eq(:accepted)
    expect(result.payload[:status]).to eq("running")
    stages = result.payload[:llm_processing_stages]
    expect(stages).to include("video_analysis", "llm_generation")
    expect(result.payload[:llm_last_stage]).to include("stage" => "llm_generation")
  end

  it "includes pipeline step timing in status responses when available" do
    event = create_story_event(
      profile: profile,
      llm_comment_status: "running",
      llm_comment_metadata: {
        "parallel_pipeline" => {
          "run_id" => "run-42",
          "status" => "running",
          "created_at" => 2.minutes.ago.iso8601,
          "steps" => {
            "ocr_analysis" => {
              "status" => "completed",
              "queue_wait_ms" => 1200,
              "run_duration_ms" => 3400,
              "total_duration_ms" => 4600,
              "attempts" => 1
            }
          }
        }
      }
    )

    result = described_class.new(
      account: account,
      event_id: event.id,
      provider: "local",
      model: nil,
      status_only: true,
      queue_inspector: queue_inspector
    ).call

    expect(result.status).to eq(:accepted)
    expect(result.payload[:llm_pipeline_step_rollup]).to be_a(Hash)
    expect(result.payload[:llm_pipeline_step_rollup]["ocr_analysis"]).to include(status: "completed", total_duration_ms: 4600)
    expect(result.payload[:llm_pipeline_timing]).to include(run_id: "run-42", status: "running")
  end

  it "queues generation job when no comment exists and status_only is false" do
    event = create_story_event(profile: profile, llm_comment_status: "failed")
    job = instance_double(ActiveJob::Base, job_id: "job-123")
    allow(GenerateLlmCommentJob).to receive(:perform_later).and_return(job)

    result = described_class.new(
      account: account,
      event_id: event.id,
      provider: "local",
      model: "tiny",
      status_only: false,
      queue_inspector: queue_inspector
    ).call

    expect(result.status).to eq(:accepted)
    expect(result.payload).to include(success: true, status: "queued", event_id: event.id, job_id: "job-123", queue_size: 2)
    expect(result.payload[:llm_processing_stages]).to include("llm_generation")
    expect(result.payload[:llm_last_stage]).to include("stage" => "queue_wait")
    expect(event.reload.llm_comment_status).to eq("queued")
    expect(event.llm_comment_job_id).to eq("job-123")
    expect(GenerateLlmCommentJob).to have_received(:perform_later).with(
      instagram_profile_event_id: event.id,
      provider: "local",
      model: "tiny",
      requested_by: "dashboard_manual_request",
      regenerate_all: false
    )
  end

  it "does not enqueue a new job when generation is already queued" do
    event = create_story_event(profile: profile, llm_comment_status: "queued", llm_comment_job_id: "job-existing")
    allow(GenerateLlmCommentJob).to receive(:perform_later)

    result = described_class.new(
      account: account,
      event_id: event.id,
      provider: "local",
      model: nil,
      status_only: false,
      queue_inspector: queue_inspector
    ).call

    expect(result.status).to eq(:accepted)
    expect(result.payload).to include(success: true, status: "queued", event_id: event.id, job_id: "job-existing")
    expect(GenerateLlmCommentJob).not_to have_received(:perform_later)
  end

  it "marks stale in-progress jobs as failed and re-enqueues a fresh generation job" do
    event = create_story_event(profile: profile, llm_comment_status: "running", llm_comment_job_id: "job-stale")
    allow(queue_inspector).to receive(:stale_comment_job?).with(event: event).and_return(true)
    job = instance_double(ActiveJob::Base, job_id: "job-new")
    allow(GenerateLlmCommentJob).to receive(:perform_later).and_return(job)

    result = described_class.new(
      account: account,
      event_id: event.id,
      provider: "local",
      model: nil,
      status_only: false,
      queue_inspector: queue_inspector
    ).call

    expect(result.status).to eq(:accepted)
    expect(result.payload).to include(success: true, status: "queued", event_id: event.id, job_id: "job-new")
    expect(event.reload.llm_comment_status).to eq("queued")
    expect(event.llm_comment_last_error).to be_nil
  end

  it "keeps in-progress status when parallel pipeline metadata is active even if queue inspector reports stale" do
    event = create_story_event(
      profile: profile,
      llm_comment_status: "running",
      llm_comment_job_id: "job-stale",
      llm_comment_metadata: {
        "parallel_pipeline" => {
          "run_id" => "run-123",
          "status" => "running",
          "created_at" => 2.minutes.ago.iso8601,
          "updated_at" => Time.current.iso8601,
          "steps" => {
            "ocr_analysis" => { "status" => "running" }
          }
        }
      }
    )
    allow(queue_inspector).to receive(:stale_comment_job?).with(event: event).and_return(true)
    allow(GenerateLlmCommentJob).to receive(:perform_later)

    result = described_class.new(
      account: account,
      event_id: event.id,
      provider: "local",
      model: nil,
      status_only: true,
      queue_inspector: queue_inspector
    ).call

    expect(result.status).to eq(:accepted)
    expect(result.payload).to include(status: "running", event_id: event.id)
    expect(event.reload.llm_comment_status).to eq("running")
    expect(GenerateLlmCommentJob).not_to have_received(:perform_later)
  end

  def create_story_event(profile:, **attrs)
    defaults = {
      kind: "story_downloaded",
      external_id: "event_#{SecureRandom.hex(6)}",
      detected_at: Time.current,
      metadata: {}
    }
    profile.instagram_profile_events.create!(defaults.merge(attrs))
  end
end
