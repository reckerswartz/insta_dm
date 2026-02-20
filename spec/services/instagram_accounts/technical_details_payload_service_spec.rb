require "rails_helper"
require "securerandom"

RSpec.describe InstagramAccounts::TechnicalDetailsPayloadService do
  def create_story_event_for(account:)
    profile = InstagramProfile.create!(instagram_account: account, username: "profile_#{SecureRandom.hex(3)}")
    profile.instagram_profile_events.create!(
      kind: "story_downloaded",
      external_id: "evt_#{SecureRandom.hex(4)}",
      detected_at: Time.current,
      metadata: {
        "upload_time" => "2026-02-18T09:00:00Z",
        "downloaded_at" => "2026-02-18T09:05:00Z"
      }
    )
  end

  it "returns not_found when event is not owned by account" do
    account = InstagramAccount.create!(username: "acct_#{SecureRandom.hex(4)}")
    other_account = InstagramAccount.create!(username: "acct_#{SecureRandom.hex(4)}")
    event = create_story_event_for(account: other_account)

    result = described_class.new(account: account, event_id: event.id).call

    expect(result.status).to eq(:not_found)
    expect(result.payload[:error]).to eq("Event not found or not accessible")
  end

  it "returns stored technical details and timeline payload when sections are complete" do
    account = InstagramAccount.create!(username: "acct_#{SecureRandom.hex(4)}")
    event = create_story_event_for(account: account)
    event.update!(
      llm_generated_comment: "hello",
      llm_comment_status: "completed",
      llm_comment_generated_at: Time.current,
      llm_comment_provider: "local",
      llm_comment_metadata: {
        "technical_details" => {
          "local_story_intelligence" => { "ok" => true },
          "analysis" => { "signals" => [] },
          "prompt_engineering" => { "version" => "v1" }
        }
      }
    )

    result = described_class.new(account: account, event_id: event.id).call

    expect(result.status).to eq(:ok)
    expect(result.payload[:event_id]).to eq(event.id)
    expect(result.payload[:technical_details]["analysis"]).to eq({ "signals" => [] })
    expect(result.payload[:timeline][:story_posted_at]).to eq("2026-02-18T09:00:00Z")
    expect(result.payload[:timeline][:downloaded_to_system_at]).to eq("2026-02-18T09:05:00Z")
  end

  it "falls back gracefully when technical details hydration raises" do
    account = InstagramAccount.create!(username: "acct_#{SecureRandom.hex(4)}")
    event = create_story_event_for(account: account)
    event.update!(llm_comment_metadata: { "technical_details" => { "analysis" => { "x" => 1 } } })
    allow(InstagramProfileEvent).to receive(:find).with(event.id).and_return(event)
    allow(event).to receive(:send).with(:build_comment_context).and_raise(StandardError, "hydrate error")

    result = described_class.new(account: account, event_id: event.id).call

    expect(result.status).to eq(:ok)
    expect(result.payload[:technical_details]).to eq({ "analysis" => { "x" => 1 } })
  end
end
