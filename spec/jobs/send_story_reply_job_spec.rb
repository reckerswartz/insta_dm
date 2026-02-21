require "rails_helper"
require "securerandom"

RSpec.describe SendStoryReplyJob do
  it "sends a story reply, persists message status, and records a sent event" do
    account = InstagramAccount.create!(username: "acct_#{SecureRandom.hex(4)}")
    profile = account.instagram_profiles.create!(username: "story_user_#{SecureRandom.hex(3)}", ig_user_id: "1789")

    messenger = instance_double(Messaging::IntegrationService)
    allow(Messaging::IntegrationService).to receive(:new).and_return(messenger)
    allow(messenger).to receive(:send_text!).and_return({ ok: true, provider_message_id: "msg_123" })

    described_class.perform_now(
      instagram_account_id: account.id,
      instagram_profile_id: profile.id,
      story_id: "abc123",
      reply_text: "Nice story!",
      story_metadata: { source: "spec" }
    )

    message = account.instagram_messages.order(id: :desc).first
    expect(message).to be_present
    expect(message.status).to eq("sent")
    expect(message.body).to eq("Nice story!")

    sent_event = profile.instagram_profile_events.find_by(kind: "story_reply_sent", external_id: "story_reply_sent:abc123")
    expect(sent_event).to be_present
    expect(sent_event.metadata["provider_message_id"]).to eq("msg_123")
    expect(sent_event.metadata["ai_reply_text"]).to eq("Nice story!")
  end

  it "does not send duplicate reply when story reply has already been sent" do
    account = InstagramAccount.create!(username: "acct_#{SecureRandom.hex(4)}")
    profile = account.instagram_profiles.create!(username: "story_user_#{SecureRandom.hex(3)}")
    profile.record_event!(
      kind: "story_reply_sent",
      external_id: "story_reply_sent:dup_1",
      metadata: { source: "existing" }
    )

    messenger = instance_double(Messaging::IntegrationService)
    allow(Messaging::IntegrationService).to receive(:new).and_return(messenger)
    expect(messenger).not_to receive(:send_text!)

    expect do
      described_class.perform_now(
        instagram_account_id: account.id,
        instagram_profile_id: profile.id,
        story_id: "dup_1",
        reply_text: "Duplicate check"
      )
    end.not_to change { account.instagram_messages.count }
  end
end
