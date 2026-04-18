require "rails_helper"
require "securerandom"

RSpec.describe LlmComment::ParallelPipelineState do
  include ActiveSupport::Testing::TimeHelpers

  after do
    travel_back
  end

  def create_story_event
    account = InstagramAccount.create!(username: "acct_state_#{SecureRandom.hex(4)}")
    profile = InstagramProfile.create!(instagram_account: account, username: "profile_state_#{SecureRandom.hex(4)}")
    InstagramProfileEvent.create!(
      instagram_profile: profile,
      kind: "story_downloaded",
      external_id: "event_state_#{SecureRandom.hex(6)}",
      detected_at: Time.current,
      llm_comment_status: "running",
      llm_comment_metadata: {},
      metadata: {}
    )
  end

  it "captures pipeline and generation durations in pipeline timing rollup" do
    event = create_story_event
    state = described_class.new(event: event)
    run_id = "run-state-timing-2"
    start_at = Time.zone.parse("2026-02-21 13:00:00 UTC")

    travel_to(start_at) do
      state.start!(
        provider: "local",
        model: "llama3.2-vision:11b",
        requested_by: "spec",
        source_job: "spec",
        active_job_id: "source-job",
        run_id: run_id
      )
    end

    travel_to(start_at + 2.seconds) do
      state.mark_generation_started!(
        run_id: run_id,
        active_job_id: "finalizer-job-1"
      )
    end

    travel_to(start_at + 9.seconds) do
      state.mark_pipeline_finished!(
        run_id: run_id,
        status: "completed",
        details: { completed_by: "spec" }
      )
    end

    timing = state.pipeline_timing(run_id: run_id)
    expect(timing["pipeline_duration_ms"]).to eq(9000)
    expect(timing["generation_duration_ms"]).to eq(7000)
  end
end
