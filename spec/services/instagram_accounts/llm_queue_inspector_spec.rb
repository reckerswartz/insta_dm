require "rails_helper"
require "securerandom"

RSpec.describe InstagramAccounts::LlmQueueInspector do
  it "returns zero queue size when adapter is not sidekiq" do
    inspector = described_class.new
    allow(inspector).to receive(:sidekiq_adapter?).and_return(false)
    expect(inspector.queue_size).to eq(0)
  end

  it "returns false for stale check when event is not in progress" do
    account = InstagramAccount.create!(username: "acct_#{SecureRandom.hex(4)}")
    profile = account.instagram_profiles.create!(username: "profile_#{SecureRandom.hex(3)}")
    event = profile.instagram_profile_events.create!(
      kind: "story_downloaded",
      external_id: "evt_#{SecureRandom.hex(4)}",
      detected_at: Time.current,
      llm_comment_status: "failed"
    )

    inspector = described_class.new
    expect(inspector.stale_comment_job?(event: event)).to eq(false)
  end
end
