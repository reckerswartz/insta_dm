require "rails_helper"
require "securerandom"

RSpec.describe GenerateStoryCommentFromPipelineJob do
  def create_story_event
    account = InstagramAccount.create!(username: "acct_story_gen_#{SecureRandom.hex(4)}")
    profile = InstagramProfile.create!(instagram_account: account, username: "profile_story_gen_#{SecureRandom.hex(4)}")
    InstagramProfileEvent.create!(
      instagram_profile: profile,
      kind: "story_downloaded",
      external_id: "event_story_gen_#{SecureRandom.hex(6)}",
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

  it "resolves payload, runs generation, and marks pipeline complete" do
    event = create_story_event
    run_id = "run-story-generation-1"
    state = prepare_pipeline(event: event, run_id: run_id)
    LlmComment::ParallelPipelineState::STEP_KEYS.each do |step|
      state.mark_step_completed!(
        run_id: run_id,
        step: step,
        status: "succeeded",
        result: { ok: true }
      )
    end

    resolver = instance_double(LlmComment::StoryIntelligencePayloadResolver, fetch!: { source: "spec", topics: [ "travel" ] })
    generator = instance_double(LlmComment::EventGenerationPipeline, call: { selected_comment: "Nice shot", relevance_score: 0.92 })
    allow(LlmComment::StoryIntelligencePayloadResolver).to receive(:new).and_return(resolver)
    allow(LlmComment::EventGenerationPipeline).to receive(:new).and_return(generator)

    described_class.new.perform(
      instagram_profile_event_id: event.id,
      pipeline_run_id: run_id,
      provider: "local",
      model: "llama3.2-vision:11b",
      requested_by: "spec"
    )

    pipeline = event.reload.llm_comment_metadata["parallel_pipeline"]
    expect(pipeline["status"]).to eq("completed")
    expect(pipeline.dig("generation", "status")).to eq("completed")
    expect(pipeline.dig("details", "step_rollup")).to be_a(Hash)
    expect(pipeline.dig("details", "pipeline_duration_ms")).to be_a(Integer)
    expect(pipeline.dig("details", "generation_duration_ms")).to be_a(Integer)
    expect(LlmComment::EventGenerationPipeline).to have_received(:new).with(
      event: an_instance_of(InstagramProfileEvent),
      provider: "local",
      model: "llama3.2-vision:11b",
      skip_media_stage_reporting: true
    )
    expect(generator).to have_received(:call).once
  end
end
