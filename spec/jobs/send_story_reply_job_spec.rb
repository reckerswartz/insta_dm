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

  it "sanitizes wrapped quotes and trailing punctuation before sending" do
    account = InstagramAccount.create!(username: "acct_#{SecureRandom.hex(4)}")
    profile = account.instagram_profiles.create!(username: "story_user_#{SecureRandom.hex(3)}", ig_user_id: "8801")

    messenger = instance_double(Messaging::IntegrationService)
    allow(Messaging::IntegrationService).to receive(:new).and_return(messenger)
    expect(messenger).to receive(:send_text!).with(
      recipient_id: "8801",
      text: "Looks great!",
      context: hash_including(source: "story_auto_reply", story_id: "abc999")
    ).and_return({ ok: true, provider_message_id: "msg_999" })

    described_class.perform_now(
      instagram_account_id: account.id,
      instagram_profile_id: profile.id,
      story_id: "abc999",
      reply_text: "\"Looks great!\",",
      story_metadata: { source: "spec" }
    )

    message = account.instagram_messages.order(id: :desc).first
    expect(message).to be_present
    expect(message.body).to eq("Looks great!")

    sent_event = profile.instagram_profile_events.find_by(kind: "story_reply_sent", external_id: "story_reply_sent:abc999")
    expect(sent_event).to be_present
    expect(sent_event.metadata["ai_reply_text"]).to eq("Looks great!")
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

  it "requeues delivery while validation is still pending" do
    account = InstagramAccount.create!(username: "acct_#{SecureRandom.hex(4)}")
    profile = account.instagram_profiles.create!(username: "story_user_#{SecureRandom.hex(3)}")
    profile.record_event!(
      kind: "story_reply_queued",
      external_id: "story_reply_queued:pending_1",
      metadata: { source: "spec" }
    )

    messenger = instance_double(Messaging::IntegrationService)
    allow(Messaging::IntegrationService).to receive(:new).and_return(messenger)
    expect(messenger).not_to receive(:send_text!)

    expect do
      described_class.perform_now(
        instagram_account_id: account.id,
        instagram_profile_id: profile.id,
        story_id: "pending_1",
        reply_text: "Hold for validation",
        validation_requested_at: Time.current.iso8601(3)
      )
    end.to have_enqueued_job(described_class).with(
      hash_including(
        instagram_account_id: account.id,
        instagram_profile_id: profile.id,
        story_id: "pending_1",
        validation_attempt: 1
      )
    )

    queue_event = profile.instagram_profile_events.find_by!(kind: "story_reply_queued", external_id: "story_reply_queued:pending_1")
    expect(queue_event.metadata["delivery_status"]).to eq("waiting_validation")
    expect(account.instagram_messages.count).to eq(0)
  end

  it "blocks delivery when validation marks story replies unavailable" do
    account = InstagramAccount.create!(username: "acct_#{SecureRandom.hex(4)}")
    profile = account.instagram_profiles.create!(
      username: "story_user_#{SecureRandom.hex(3)}",
      story_interaction_state: "unavailable",
      story_interaction_reason: "api_can_reply_false",
      story_interaction_checked_at: Time.current,
      story_interaction_retry_after_at: 2.hours.from_now
    )
    profile.record_event!(
      kind: "story_reply_queued",
      external_id: "story_reply_queued:blocked_1",
      metadata: { source: "spec" }
    )

    messenger = instance_double(Messaging::IntegrationService)
    allow(Messaging::IntegrationService).to receive(:new).and_return(messenger)
    expect(messenger).not_to receive(:send_text!)

    expect do
      described_class.perform_now(
        instagram_account_id: account.id,
        instagram_profile_id: profile.id,
        story_id: "blocked_1",
        reply_text: "Should not send",
        validation_requested_at: 1.minute.ago.iso8601(3)
      )
    end.not_to change { account.instagram_messages.count }

    queue_event = profile.instagram_profile_events.find_by!(kind: "story_reply_queued", external_id: "story_reply_queued:blocked_1")
    expect(queue_event.metadata["delivery_status"]).to eq("blocked_validation")
    expect(queue_event.metadata["interaction_reason"]).to eq("api_can_reply_false")
  end
end
