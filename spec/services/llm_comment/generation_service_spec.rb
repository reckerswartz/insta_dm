require "rails_helper"
require "securerandom"

RSpec.describe LlmComment::GenerationService do
  def build_story_event(status: "queued", job_id: nil)
    account = InstagramAccount.create!(username: "acct_#{SecureRandom.hex(4)}")
    profile = InstagramProfile.create!(
      instagram_account: account,
      username: "profile_#{SecureRandom.hex(4)}"
    )
    InstagramProfileEvent.create!(
      instagram_profile: profile,
      kind: "story_downloaded",
      external_id: "event_#{SecureRandom.hex(4)}",
      detected_at: Time.current,
      llm_comment_status: status,
      llm_comment_job_id: job_id,
      metadata: {}
    )
  end

  it "skips duplicate execution when another running job already owns the event" do
    event = build_story_event(status: "running", job_id: "job-1")
    service = described_class.new(instagram_profile_event_id: event.id)

    allow(service).to receive(:prepare_profile_context)
    allow(service).to receive(:persist_profile_preparation_snapshot)
    allow(service).to receive(:generate_comment)

    Current.set(active_job_id: "job-2") { service.call }

    expect(service).not_to have_received(:generate_comment)
    expect(event.reload.llm_comment_job_id).to eq("job-1")
    expect(event.llm_comment_status).to eq("running")
  end

  it "raises when slot claiming fails unexpectedly so job retries can run" do
    event = build_story_event(status: "queued")
    service = described_class.new(instagram_profile_event_id: event.id)

    allow(service).to receive(:event).and_return(event)
    allow(event).to receive(:with_lock).and_raise(ActiveRecord::StatementInvalid.new("lock error"))

    expect do
      Current.set(active_job_id: "job-9") { service.call }
    end.to raise_error(ActiveRecord::StatementInvalid)
  end

  it "claims queued events even when a newer deferred job id is running" do
    event = build_story_event(status: "queued", job_id: "job-old")
    service = described_class.new(instagram_profile_event_id: event.id)

    allow(service).to receive(:prepare_profile_context)
    allow(service).to receive(:persist_profile_preparation_snapshot)
    allow(service).to receive(:generate_comment) do
      service.instance_variable_set(:@result, { source: "spec" })
    end

    Current.set(active_job_id: "job-new") { service.call }

    expect(service).to have_received(:generate_comment)
    expect(event.reload.llm_comment_status).to eq("running")
    expect(event.llm_comment_job_id).to eq("job-new")
  end
end
