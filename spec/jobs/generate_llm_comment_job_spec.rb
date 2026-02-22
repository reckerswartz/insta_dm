require "rails_helper"
require "securerandom"

RSpec.describe GenerateLlmCommentJob do
  include ActiveJob::TestHelper

  let(:job) { described_class.new }
  let(:service) { instance_double(LlmComment::GenerationService, call: true) }

  before do
    clear_enqueued_jobs
    clear_performed_jobs
  end

  it "runs generation service when resources are available" do
    allow(Ops::ResourceGuard).to receive(:allow_ai_task?).and_return(
      { allow: true, reason: nil, retry_in_seconds: nil, snapshot: {} }
    )
    expect(LlmComment::GenerationService).to receive(:new).with(
      instagram_profile_event_id: 42,
      provider: "local",
      model: "mistral:7b",
      requested_by: "spec",
      regenerate_all: false
    ).and_return(service)

    job.perform(
      instagram_profile_event_id: 42,
      provider: "local",
      model: "mistral:7b",
      requested_by: "spec"
    )
  end

  it "re-enqueues the job when resource guard blocks execution" do
    allow(Ops::ResourceGuard).to receive(:allow_ai_task?).and_return(
      { allow: false, reason: "high_cpu_load", retry_in_seconds: 12, snapshot: { load_per_core: 2.0 } }
    )
    allow(LlmComment::GenerationService).to receive(:new)
    account = InstagramAccount.create!(username: "acct_defer_#{SecureRandom.hex(4)}")
    profile = InstagramProfile.create!(instagram_account: account, username: "profile_defer_#{SecureRandom.hex(3)}")
    event = profile.instagram_profile_events.create!(
      kind: "story_downloaded",
      external_id: "evt_defer_#{SecureRandom.hex(4)}",
      detected_at: Time.current,
      llm_comment_status: "queued",
      llm_comment_job_id: "job-old",
      metadata: {}
    )
    deferred_job = instance_double(ActiveJob::Base, job_id: "job-new")

    expect(described_class).to receive(:set).with(wait: 12.seconds).and_return(described_class)
    expect(described_class).to receive(:perform_later).with(
      instagram_profile_event_id: event.id,
      provider: "local",
      model: nil,
      requested_by: "system",
      defer_attempt: 1,
      regenerate_all: false
    ).and_return(deferred_job)

    job.perform(instagram_profile_event_id: event.id, provider: "local", requested_by: "system")
    expect(LlmComment::GenerationService).not_to have_received(:new)
    expect(event.reload.llm_comment_status).to eq("queued")
    expect(event.llm_comment_job_id).to eq("job-new")
  end

  it "marks comment generation failed when resource guard defer attempts are exhausted" do
    allow(Ops::ResourceGuard).to receive(:allow_ai_task?).and_return(
      { allow: false, reason: "high_cpu_load", retry_in_seconds: 20, snapshot: { load_per_core: 2.0 } }
    )
    allow(LlmComment::GenerationService).to receive(:new)
    account = InstagramAccount.create!(username: "acct_defer_exhaust_#{SecureRandom.hex(4)}")
    profile = InstagramProfile.create!(instagram_account: account, username: "profile_defer_exhaust_#{SecureRandom.hex(3)}")
    event = profile.instagram_profile_events.create!(
      kind: "story_downloaded",
      external_id: "evt_defer_exhaust_#{SecureRandom.hex(4)}",
      detected_at: Time.current,
      llm_comment_status: "queued",
      llm_comment_job_id: "job-old",
      metadata: {}
    )

    expect(described_class).not_to receive(:perform_later)
    job.perform(
      instagram_profile_event_id: event.id,
      provider: "local",
      requested_by: "system",
      defer_attempt: described_class::MAX_RESOURCE_DEFER_ATTEMPTS
    )

    event.reload
    expect(event.llm_comment_status).to eq("failed")
    expect(event.llm_comment_last_error).to include("deferred too many times")
  end

  it "marks llm comment status as failed when timeout occurs" do
    allow(Ops::ResourceGuard).to receive(:allow_ai_task?).and_return(
      { allow: true, reason: nil, retry_in_seconds: nil, snapshot: {} }
    )

    account = InstagramAccount.create!(username: "acct_timeout_#{SecureRandom.hex(4)}")
    profile = InstagramProfile.create!(instagram_account: account, username: "profile_timeout_#{SecureRandom.hex(3)}")
    event = profile.instagram_profile_events.create!(
      kind: "story_downloaded",
      external_id: "evt_timeout_#{SecureRandom.hex(4)}",
      detected_at: Time.current,
      llm_comment_status: "running",
      metadata: {}
    )

    allow(LlmComment::GenerationService).to receive(:new).and_return(instance_double(LlmComment::GenerationService, call: true))
    allow(Timeout).to receive(:timeout).and_raise(Timeout::Error)

    job.perform(instagram_profile_event_id: event.id, provider: "local", requested_by: "spec")

    expect(event.reload.llm_comment_status).to eq("failed")
    expect(event.llm_comment_last_error).to include("timed out")
  end

  it "passes regenerate_all through to generation service" do
    allow(Ops::ResourceGuard).to receive(:allow_ai_task?).and_return(
      { allow: true, reason: nil, retry_in_seconds: nil, snapshot: {} }
    )
    expect(LlmComment::GenerationService).to receive(:new).with(
      instagram_profile_event_id: 77,
      provider: "local",
      model: nil,
      requested_by: "spec",
      regenerate_all: true
    ).and_return(service)

    job.perform(
      instagram_profile_event_id: 77,
      provider: "local",
      requested_by: "spec",
      regenerate_all: true
    )
  end
end
