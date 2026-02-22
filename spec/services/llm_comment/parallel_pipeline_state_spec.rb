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
        model: "llama3.2-vision:11b",
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

  it "resumes completed steps and shared payload from a failed run by default" do
    event = create_story_event
    previous_pipeline = {
      "run_id" => "run-old-1",
      "status" => "failed",
      "steps" => {
        "ocr_analysis" => {
          "status" => "succeeded",
          "attempts" => 1,
          "result" => { "text_present" => true },
          "queued_at" => 3.minutes.ago.iso8601,
          "started_at" => 3.minutes.ago.iso8601,
          "finished_at" => 2.minutes.ago.iso8601,
          "total_duration_ms" => 1100
        },
        "vision_detection" => {
          "status" => "failed",
          "attempts" => 2,
          "error" => "timeout"
        },
        "face_recognition" => {
          "status" => "succeeded",
          "attempts" => 1,
          "result" => { "face_count" => 1 }
        },
        "metadata_extraction" => {
          "status" => "pending",
          "attempts" => 0
        }
      },
      "shared_payload" => {
        "status" => "ready",
        "payload" => { "ocr_text" => "hello world" }
      }
    }
    event.update!(llm_comment_metadata: { "parallel_pipeline" => previous_pipeline })

    state = described_class.new(event: event)
    result = state.start!(
      provider: "local",
      model: "llama3.2-vision:11b",
      requested_by: "spec",
      source_job: "spec",
      active_job_id: "source-job",
      run_id: "run-new-1"
    )

    expect(result[:started]).to eq(true)
    expect(result[:resume_mode]).to eq("resume_incomplete")
    expect(result[:resumed_from_run_id]).to eq("run-old-1")

    pipeline = state.pipeline_for(run_id: "run-new-1")
    expect(pipeline.dig("steps", "ocr_analysis", "status")).to eq("succeeded")
    expect(pipeline.dig("steps", "face_recognition", "status")).to eq("succeeded")
    expect(pipeline.dig("steps", "vision_detection", "status")).to eq("pending")
    expect(pipeline.dig("steps", "metadata_extraction", "status")).to eq("pending")
    expect(pipeline.dig("shared_payload", "status")).to eq("ready")
    expect(pipeline.dig("shared_payload", "payload", "ocr_text")).to eq("hello world")

    expect(state.steps_requiring_execution(run_id: "run-new-1")).to match_array(%w[vision_detection metadata_extraction])
  end

  it "skips resume reuse when regenerate_all is requested" do
    event = create_story_event
    event.update!(
      llm_comment_metadata: {
        "parallel_pipeline" => {
          "run_id" => "run-old-2",
          "status" => "failed",
          "steps" => {
            "ocr_analysis" => { "status" => "succeeded" }
          },
          "shared_payload" => {
            "status" => "ready",
            "payload" => { "ocr_text" => "cached" }
          }
        }
      }
    )

    state = described_class.new(event: event)
    result = state.start!(
      provider: "local",
      model: "llama3.2-vision:11b",
      requested_by: "spec",
      source_job: "spec",
      active_job_id: "source-job",
      regenerate_all: true,
      run_id: "run-new-2"
    )

    expect(result[:resume_mode]).to eq("regenerate_all")
    pipeline = state.pipeline_for(run_id: "run-new-2")
    expect(pipeline.dig("steps", "ocr_analysis", "status")).to eq("pending")
    expect(pipeline["shared_payload"]).to be_nil
    expect(state.steps_requiring_execution(run_id: "run-new-2")).to match_array(LlmComment::ParallelPipelineState::STEP_KEYS)
  end

  it "resumes from a stale running pipeline when prior execution was interrupted" do
    event = create_story_event
    stale_time = 40.minutes.ago
    event.update!(
      llm_comment_metadata: {
        "parallel_pipeline" => {
          "run_id" => "run-stale-1",
          "status" => "running",
          "created_at" => stale_time.iso8601,
          "updated_at" => stale_time.iso8601,
          "steps" => {
            "ocr_analysis" => { "status" => "succeeded", "result" => { "text_present" => true } },
            "vision_detection" => { "status" => "running", "attempts" => 1 },
            "face_recognition" => { "status" => "pending" },
            "metadata_extraction" => { "status" => "pending" }
          }
        }
      }
    )

    state = described_class.new(event: event)
    result = state.start!(
      provider: "local",
      model: "llama3.2-vision:11b",
      requested_by: "spec",
      source_job: "spec",
      active_job_id: "source-job",
      run_id: "run-resumed-1"
    )

    expect(result[:started]).to eq(true)
    expect(result[:resume_mode]).to eq("resume_incomplete")
    expect(result[:resumed_from_run_id]).to eq("run-stale-1")
    expect(state.pipeline_for(run_id: "run-resumed-1").dig("steps", "ocr_analysis", "status")).to eq("succeeded")
    expect(state.steps_requiring_execution(run_id: "run-resumed-1")).to include("vision_detection")
  end

  it "treats deferred steps as non-blocking for generation readiness" do
    event = create_story_event
    state = described_class.new(event: event)
    run_id = "run-required-only-1"

    state.start!(
      provider: "local",
      model: "llama3.2-vision:11b",
      requested_by: "spec",
      source_job: "spec",
      active_job_id: "source-job",
      run_id: run_id
    )

    %w[ocr_analysis vision_detection metadata_extraction].each do |step|
      state.mark_step_completed!(
        run_id: run_id,
        step: step,
        status: "succeeded",
        result: { ok: true }
      )
    end

    expect(state.required_steps(run_id: run_id)).to match_array(%w[ocr_analysis vision_detection metadata_extraction])
    expect(state.required_steps_terminal?(run_id: run_id)).to eq(true)
    expect(state.all_steps_terminal?(run_id: run_id)).to eq(true)
    expect(state.step_state(run_id: run_id, step: "face_recognition").to_h["status"]).to eq("pending")
  end
end
