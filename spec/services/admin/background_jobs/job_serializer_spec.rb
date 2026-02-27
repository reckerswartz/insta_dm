require "rails_helper"

RSpec.describe Admin::BackgroundJobs::JobSerializer do
  FakeSidekiqJob = Struct.new(:item)

  subject(:serializer) { described_class.new }

  def sidekiq_payload(job_class:, queue_name:, at: nil, args_payload: {})
    {
      "jid" => "jid_123",
      "wrapped" => job_class,
      "queue" => queue_name,
      "at" => at,
      "args" => [
        {
          "job_class" => job_class,
          "job_id" => "active_job_123",
          "provider_job_id" => "provider_job_123",
          "arguments" => [ args_payload ]
        }
      ]
    }.compact
  end

  it "marks dependency polling as intentional scheduled delay" do
    run_at = 3.minutes.from_now
    payload = sidekiq_payload(
      job_class: "FinalizeStoryCommentPipelineJob",
      queue_name: "ai_pipeline_orchestration_queue",
      at: run_at.to_f,
      args_payload: {
        "instagram_profile_event_id" => 44,
        "pipeline_run_id" => "run_1",
        "attempts" => 2
      }
    )

    row = serializer.serialize_sidekiq(
      job: FakeSidekiqJob.new(payload),
      status: "scheduled",
      queue_name: "ai_pipeline_orchestration_queue"
    )

    expect(row[:queue_state]).to eq("scheduled")
    expect(row[:scheduling_reason_code]).to eq("dependency_wait_poll")
    expect(row[:scheduler_service]).to eq("FinalizeStoryCommentPipelineJob")
    expect(row[:scheduling_intentional]).to eq(true)
    expect(row[:scheduled_for_at]).to be_within(1.second).of(run_at)
    expect(row[:scheduled_in_seconds]).to be_between(160, 200)
  end

  it "labels LLM resource guard deferrals in scheduled queue rows" do
    run_at = 40.seconds.from_now
    payload = sidekiq_payload(
      job_class: "GenerateLlmCommentJob",
      queue_name: "ai_llm_comment_queue",
      at: run_at.to_f,
      args_payload: {
        "instagram_profile_event_id" => 57,
        "defer_attempt" => 1,
        "requested_by" => "dashboard_manual_request"
      }
    )

    row = serializer.serialize_sidekiq(
      job: FakeSidekiqJob.new(payload),
      status: "scheduled",
      queue_name: "ai_llm_comment_queue"
    )

    expect(row[:queue_state]).to eq("scheduled")
    expect(row[:scheduling_reason_code]).to eq("resource_guard_delay")
    expect(row[:scheduler_service]).to eq("GenerateLlmCommentJob")
    expect(row[:scheduling_intentional]).to eq(true)
  end

  it "maps retries to scheduled state and retry backoff reason" do
    payload = sidekiq_payload(
      job_class: "GenerateLlmCommentJob",
      queue_name: "ai_llm_comment_queue",
      args_payload: { "instagram_profile_event_id" => 61 }
    ).merge("retry_count" => 2)

    row = serializer.serialize_sidekiq(
      job: FakeSidekiqJob.new(payload),
      status: "retry",
      queue_name: "ai_llm_comment_queue"
    )

    expect(row[:queue_state]).to eq("scheduled")
    expect(row[:scheduling_reason_code]).to eq("retry_backoff")
    expect(row[:scheduler_service]).to eq("Sidekiq retry set")
    expect(row[:scheduling_intentional]).to eq(true)
  end
end
