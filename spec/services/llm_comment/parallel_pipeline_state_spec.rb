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

  it "captures queue wait and run durations for step timing rollups" do
    event = create_story_event
    state = described_class.new(event: event)
    run_id = "run-state-timing-1"
    start_at = Time.zone.parse("2026-02-21 12:00:00 UTC")

    travel_to(start_at) do
      state.start!(
        provider: "local",
        model: "mistral:7b",
        requested_by: "spec",
        source_job: "spec",
        active_job_id: "source-job",
        run_id: run_id
      )
      state.mark_step_queued!(
        run_id: run_id,
        step: "ocr_analysis",
        queue_name: "ai_ocr_queue",
        active_job_id: "ocr-job-1"
      )
    end

    travel_to(start_at + 4.seconds) do
      state.mark_step_running!(
        run_id: run_id,
        step: "ocr_analysis",
        queue_name: "ai_ocr_queue",
        active_job_id: "ocr-job-1"
      )
    end

    travel_to(start_at + 13.seconds) do
      state.mark_step_completed!(
        run_id: run_id,
        step: "ocr_analysis",
        status: "succeeded",
        result: { ok: true }
      )
    end

    row = state.step_state(run_id: run_id, step: "ocr_analysis")
    expect(row["queue_wait_ms"]).to eq(4000)
    expect(row["run_duration_ms"]).to eq(9000)
    expect(row["total_duration_ms"]).to eq(13000)

    rollup = state.step_rollup(run_id: run_id)
    expect(rollup.dig("ocr_analysis", "queue_wait_ms")).to eq(4000)
    expect(rollup.dig("ocr_analysis", "run_duration_ms")).to eq(9000)
    expect(rollup.dig("ocr_analysis", "total_duration_ms")).to eq(13000)
  end

  it "captures pipeline and generation durations in pipeline timing rollup" do
    event = create_story_event
    state = described_class.new(event: event)
    run_id = "run-state-timing-2"
    start_at = Time.zone.parse("2026-02-21 13:00:00 UTC")

    travel_to(start_at) do
      state.start!(
        provider: "local",
        model: "mistral:7b",
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
