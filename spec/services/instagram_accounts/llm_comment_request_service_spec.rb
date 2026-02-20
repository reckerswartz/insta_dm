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
    expect(event.reload.llm_comment_status).to eq("queued")
    expect(event.llm_comment_job_id).to eq("job-123")
    expect(GenerateLlmCommentJob).to have_received(:perform_later).with(
      instagram_profile_event_id: event.id,
      provider: "local",
      model: "tiny",
      requested_by: "dashboard_manual_request"
    )
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
