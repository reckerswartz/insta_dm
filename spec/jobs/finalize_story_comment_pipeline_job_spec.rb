require "rails_helper"
require "securerandom"

RSpec.describe FinalizeStoryCommentPipelineJob do
  def create_story_event
    account = InstagramAccount.create!(username: "acct_finalizer_#{SecureRandom.hex(4)}")
    profile = InstagramProfile.create!(instagram_account: account, username: "profile_finalizer_#{SecureRandom.hex(4)}")
    InstagramProfileEvent.create!(
      instagram_profile: profile,
      kind: "story_downloaded",
      external_id: "event_finalizer_#{SecureRandom.hex(6)}",
      detected_at: Time.current,
      llm_comment_status: "running",
      llm_comment_metadata: {},
      metadata: {}
    )
  end

  def prepare_pipeline(event:, run_id:)
    state = LlmComment::ParallelPipelineState.new(event: event)
    state.start!(
      provider: "local",
      model: "llama3.2-vision:11b",
      requested_by: "spec",
      source_job: "spec",
      active_job_id: "job-source",
      run_id: run_id
    )
    state
  end

  it "re-enqueues finalizer while stage jobs are still running" do
    event = create_story_event
    run_id = "run-wait-1"
    prepare_pipeline(event: event, run_id: run_id)

    allow(described_class).to receive(:set).and_return(described_class)
    allow(described_class).to receive(:perform_later)

    described_class.new.perform(
      instagram_profile_event_id: event.id,
      pipeline_run_id: run_id,
      provider: "local",
      model: nil,
      requested_by: "spec",
      attempts: 0
    )

    expect(described_class).to have_received(:set).once
    expect(described_class).to have_received(:perform_later).once
    expect(event.reload.llm_comment_metadata.dig("parallel_pipeline", "status")).to eq("running")
  end

  it "continues to generation once required stage jobs are terminal even if deferred steps are pending" do
    event = create_story_event
    run_id = "run-complete-1"
    state = prepare_pipeline(event: event, run_id: run_id)
    LlmComment::ParallelPipelineState::REQUIRED_STEP_KEYS.each do |step|
      state.mark_step_completed!(
        run_id: run_id,
        step: step,
        status: "succeeded",
        result: { ok: true }
      )
    end

    generation_job = instance_double(ActiveJob::Base, job_id: "story-generation-1", queue_name: "ai_llm_comment_queue")
    allow(GenerateStoryCommentFromPipelineJob).to receive(:perform_later).and_return(generation_job)

    described_class.new.perform(
      instagram_profile_event_id: event.id,
      pipeline_run_id: run_id,
      provider: "local",
      model: "llama3.2-vision:11b",
      requested_by: "spec",
      attempts: 0
    )

    pipeline = event.reload.llm_comment_metadata["parallel_pipeline"]
    expect(pipeline["status"]).to eq("running")
    expect(pipeline.dig("generation", "status")).to eq("running")
    expect(pipeline.dig("steps", "face_recognition", "status")).to eq("pending")
    expect(GenerateStoryCommentFromPipelineJob).to have_received(:perform_later).with(
      instagram_profile_event_id: event.id,
      pipeline_run_id: run_id,
      provider: "local",
      model: "llama3.2-vision:11b",
      requested_by: "spec"
    )
  end
end
