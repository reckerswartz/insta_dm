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

  it "enqueues independent stage jobs and finalizer with pipeline state tracking" do
    event = create_story_event
    ocr_job = instance_double(ActiveJob::Base, job_id: "ocr-job-1", queue_name: "ai_ocr_queue")
    vision_job = instance_double(ActiveJob::Base, job_id: "vision-job-1", queue_name: "ai_visual_queue")
    face_job = instance_double(ActiveJob::Base, job_id: "face-job-1", queue_name: "ai_face_queue")
    metadata_job = instance_double(ActiveJob::Base, job_id: "meta-job-1", queue_name: "ai_metadata_queue")
    finalizer_job = instance_double(ActiveJob::Base, job_id: "finalizer-job-1", queue_name: "ai_pipeline_orchestration_queue")

    allow(ProcessStoryCommentOcrJob).to receive(:perform_later).and_return(ocr_job)
    allow(ProcessStoryCommentVisionJob).to receive(:perform_later).and_return(vision_job)
    allow(ProcessStoryCommentFaceJob).to receive(:perform_later).and_return(face_job)
    allow(ProcessStoryCommentMetadataJob).to receive(:perform_later).and_return(metadata_job)
    allow(FinalizeStoryCommentPipelineJob).to receive(:perform_later).and_return(finalizer_job)

    result = described_class.new(
      event: event,
      provider: "local",
      model: "llama3.2-vision:11b",
      requested_by: "spec",
      source_job_id: "job-source-1"
    ).call

    expect(result[:status]).to eq("pipeline_enqueued")
    expect(result[:run_id]).to be_present
    expect(result[:finalizer_job_id]).to eq("finalizer-job-1")

    expect(ProcessStoryCommentOcrJob).to have_received(:perform_later).once
    expect(ProcessStoryCommentVisionJob).to have_received(:perform_later).once
    expect(ProcessStoryCommentFaceJob).to have_received(:perform_later).once
    expect(ProcessStoryCommentMetadataJob).to have_received(:perform_later).once
    expect(FinalizeStoryCommentPipelineJob).to have_received(:perform_later).once

    pipeline = event.reload.llm_comment_metadata["parallel_pipeline"]
    expect(pipeline).to be_a(Hash)
    expect(pipeline["run_id"]).to eq(result[:run_id])
    expect(pipeline["status"]).to eq("running")
    expect(pipeline.dig("steps", "ocr_analysis", "status")).to eq("queued")
    expect(pipeline.dig("steps", "vision_detection", "status")).to eq("queued")
    expect(pipeline.dig("steps", "face_recognition", "status")).to eq("queued")
    expect(pipeline.dig("steps", "metadata_extraction", "status")).to eq("queued")
  end

  it "reuses the active pipeline run when one is already running" do
    event = create_story_event
    event.update!(
      llm_comment_metadata: {
        "parallel_pipeline" => {
          "run_id" => "run-existing-1",
          "status" => "running",
          "steps" => {}
        }
      }
    )

    allow(ProcessStoryCommentOcrJob).to receive(:perform_later)
    allow(FinalizeStoryCommentPipelineJob).to receive(:perform_later)

    result = described_class.new(
      event: event,
      provider: "local",
      model: nil,
      requested_by: "spec",
      source_job_id: "job-source-2"
    ).call

    expect(result).to include(status: "pipeline_already_running", run_id: "run-existing-1")
    expect(ProcessStoryCommentOcrJob).not_to have_received(:perform_later)
    expect(FinalizeStoryCommentPipelineJob).not_to have_received(:perform_later)
  end

  it "enqueues only failed or incomplete steps when resuming a failed pipeline" do
    event = create_story_event
    event.update!(
      llm_comment_metadata: {
        "parallel_pipeline" => {
          "run_id" => "run-failed-1",
          "status" => "failed",
          "steps" => {
            "ocr_analysis" => { "status" => "succeeded", "attempts" => 1 },
            "vision_detection" => { "status" => "failed", "attempts" => 1, "error" => "timeout" },
            "face_recognition" => { "status" => "succeeded", "attempts" => 1 },
            "metadata_extraction" => { "status" => "succeeded", "attempts" => 1 }
          }
        }
      }
    )

    vision_job = instance_double(ActiveJob::Base, job_id: "vision-resume-1", queue_name: "ai_visual_queue")
    finalizer_job = instance_double(ActiveJob::Base, job_id: "finalizer-resume-1", queue_name: "ai_pipeline_orchestration_queue")
    allow(ProcessStoryCommentOcrJob).to receive(:perform_later)
    allow(ProcessStoryCommentVisionJob).to receive(:perform_later).and_return(vision_job)
    allow(ProcessStoryCommentFaceJob).to receive(:perform_later)
    allow(ProcessStoryCommentMetadataJob).to receive(:perform_later)
    allow(FinalizeStoryCommentPipelineJob).to receive(:perform_later).and_return(finalizer_job)

    result = described_class.new(
      event: event,
      provider: "local",
      model: "llama3.2-vision:11b",
      requested_by: "spec",
      source_job_id: "job-source-resume-1"
    ).call

    expect(result[:status]).to eq("pipeline_enqueued")
    expect(result[:resume_mode]).to eq("resume_incomplete")
    expect(result[:stage_jobs_requested]).to match_array(%w[vision_detection])
    expect(result[:stage_jobs].keys).to match_array(%w[vision_detection])
    expect(ProcessStoryCommentVisionJob).to have_received(:perform_later).once
    expect(ProcessStoryCommentOcrJob).not_to have_received(:perform_later)
    expect(ProcessStoryCommentFaceJob).not_to have_received(:perform_later)
    expect(ProcessStoryCommentMetadataJob).not_to have_received(:perform_later)
  end

  it "skips stage job enqueue entirely when all analysis steps are already complete" do
    event = create_story_event
    event.update!(
      llm_comment_metadata: {
        "parallel_pipeline" => {
          "run_id" => "run-failed-after-analysis",
          "status" => "failed",
          "steps" => {
            "ocr_analysis" => { "status" => "succeeded" },
            "vision_detection" => { "status" => "succeeded" },
            "face_recognition" => { "status" => "succeeded" },
            "metadata_extraction" => { "status" => "succeeded" }
          }
        }
      }
    )

    allow(ProcessStoryCommentOcrJob).to receive(:perform_later)
    allow(ProcessStoryCommentVisionJob).to receive(:perform_later)
    allow(ProcessStoryCommentFaceJob).to receive(:perform_later)
    allow(ProcessStoryCommentMetadataJob).to receive(:perform_later)
    finalizer_job = instance_double(ActiveJob::Base, job_id: "finalizer-only-1", queue_name: "ai_pipeline_orchestration_queue")
    allow(FinalizeStoryCommentPipelineJob).to receive(:perform_later).and_return(finalizer_job)

    result = described_class.new(
      event: event,
      provider: "local",
      model: "llama3.2-vision:11b",
      requested_by: "spec",
      source_job_id: "job-source-resume-2"
    ).call

    expect(result[:stage_jobs]).to eq({})
    expect(result[:stage_jobs_requested]).to eq([])
    expect(FinalizeStoryCommentPipelineJob).to have_received(:perform_later).once
    expect(ProcessStoryCommentOcrJob).not_to have_received(:perform_later)
    expect(ProcessStoryCommentVisionJob).not_to have_received(:perform_later)
    expect(ProcessStoryCommentFaceJob).not_to have_received(:perform_later)
    expect(ProcessStoryCommentMetadataJob).not_to have_received(:perform_later)
  end
end
