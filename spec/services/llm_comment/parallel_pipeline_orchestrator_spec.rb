require "rails_helper"
require "securerandom"

RSpec.describe LlmComment::ParallelPipelineOrchestrator do
  def create_story_event
    account = InstagramAccount.create!(username: "acct_pipeline_#{SecureRandom.hex(4)}")
    profile = InstagramProfile.create!(instagram_account: account, username: "profile_pipeline_#{SecureRandom.hex(4)}")
    InstagramProfileEvent.create!(
      instagram_profile: profile,
      kind: "story_downloaded",
      external_id: "event_pipeline_#{SecureRandom.hex(6)}",
      detected_at: Time.current,
      llm_comment_status: "running",
      llm_comment_metadata: {},
      metadata: {}
    )
  end

  it "enqueues generation immediately when no required stage jobs exist" do
    event = create_story_event
    generation_job = instance_double(ActiveJob::Base, job_id: "generation-job-1", queue_name: "ai_llm_comment_queue")

    allow(ProcessStoryCommentFaceJob).to receive(:perform_later)
    allow(GenerateStoryCommentFromPipelineJob).to receive(:perform_later).and_return(generation_job)
    allow(FinalizeStoryCommentPipelineJob).to receive(:perform_later)

    result = described_class.new(
      event: event,
      provider: "local",
      model: "llama3.2-vision:11b",
      requested_by: "spec",
      source_job_id: "job-source-1"
    ).call

    expect(result[:status]).to eq("pipeline_enqueued")
    expect(result[:run_id]).to be_present
    expect(result[:generation_job_id]).to eq("generation-job-1")
    expect(result[:finalizer_job_id]).to be_nil

    expect(ProcessStoryCommentFaceJob).not_to have_received(:perform_later)
    expect(GenerateStoryCommentFromPipelineJob).to have_received(:perform_later).once
    expect(FinalizeStoryCommentPipelineJob).not_to have_received(:perform_later)

    pipeline = event.reload.llm_comment_metadata["parallel_pipeline"]
    expect(pipeline).to be_a(Hash)
    expect(pipeline["run_id"]).to eq(result[:run_id])
    expect(pipeline["status"]).to eq("running")
    expect(result[:stage_jobs_requested]).to eq([])
    expect(pipeline.dig("steps", "face_recognition", "status")).to eq("pending")
  end

  it "reuses the active pipeline run when one is already running" do
    event = create_story_event
    event.update!(
      llm_comment_metadata: {
        "parallel_pipeline" => {
          "run_id" => "run-existing-1",
          "status" => "running",
          "created_at" => 30.seconds.ago.iso8601,
          "updated_at" => Time.current.iso8601,
          "steps" => {}
        }
      }
    )

    allow(GenerateStoryCommentFromPipelineJob).to receive(:perform_later)
    allow(FinalizeStoryCommentPipelineJob).to receive(:perform_later)

    result = described_class.new(
      event: event,
      provider: "local",
      model: nil,
      requested_by: "spec",
      source_job_id: "job-source-2"
    ).call

    expect(result).to include(status: "pipeline_already_running", run_id: "run-existing-1")
    expect(GenerateStoryCommentFromPipelineJob).not_to have_received(:perform_later)
    expect(FinalizeStoryCommentPipelineJob).not_to have_received(:perform_later)
  end

  it "resumes a failed pipeline and re-queues generation when no required steps remain" do
    event = create_story_event
    event.update!(
      llm_comment_metadata: {
        "parallel_pipeline" => {
          "run_id" => "run-failed-1",
          "status" => "failed",
          "steps" => {
            "face_recognition" => { "status" => "succeeded", "attempts" => 1 }
          }
        }
      }
    )

    generation_job = instance_double(ActiveJob::Base, job_id: "generation-resume-1", queue_name: "ai_llm_comment_queue")
    allow(ProcessStoryCommentFaceJob).to receive(:perform_later)
    allow(GenerateStoryCommentFromPipelineJob).to receive(:perform_later).and_return(generation_job)
    allow(FinalizeStoryCommentPipelineJob).to receive(:perform_later)

    result = described_class.new(
      event: event,
      provider: "local",
      model: "llama3.2-vision:11b",
      requested_by: "spec",
      source_job_id: "job-source-resume-1"
    ).call

    expect(result[:status]).to eq("pipeline_enqueued")
    expect(result[:resume_mode]).to eq("resume_incomplete")
    expect(result[:stage_jobs_requested]).to eq([])
    expect(result[:stage_jobs]).to eq({})
    expect(result[:generation_job_id]).to eq("generation-resume-1")
    expect(GenerateStoryCommentFromPipelineJob).to have_received(:perform_later).once
    expect(FinalizeStoryCommentPipelineJob).not_to have_received(:perform_later)
    expect(ProcessStoryCommentFaceJob).not_to have_received(:perform_later)
  end

  it "skips stage job enqueue entirely when all analysis steps are already complete" do
    event = create_story_event
    event.update!(
      llm_comment_metadata: {
        "parallel_pipeline" => {
          "run_id" => "run-failed-after-analysis",
          "status" => "failed",
          "steps" => {
            "face_recognition" => { "status" => "succeeded" }
          }
        }
      }
    )

    allow(ProcessStoryCommentFaceJob).to receive(:perform_later)
    generation_job = instance_double(ActiveJob::Base, job_id: "generation-only-1", queue_name: "ai_llm_comment_queue")
    allow(GenerateStoryCommentFromPipelineJob).to receive(:perform_later).and_return(generation_job)
    allow(FinalizeStoryCommentPipelineJob).to receive(:perform_later)

    result = described_class.new(
      event: event,
      provider: "local",
      model: "llama3.2-vision:11b",
      requested_by: "spec",
      source_job_id: "job-source-resume-2"
    ).call

    expect(result[:stage_jobs]).to eq({})
    expect(result[:stage_jobs_requested]).to eq([])
    expect(result[:generation_job_id]).to eq("generation-only-1")
    expect(GenerateStoryCommentFromPipelineJob).to have_received(:perform_later).once
    expect(FinalizeStoryCommentPipelineJob).not_to have_received(:perform_later)
    expect(ProcessStoryCommentFaceJob).not_to have_received(:perform_later)
  end
end
