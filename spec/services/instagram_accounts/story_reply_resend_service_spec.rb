require "rails_helper"
require "securerandom"
require "stringio"

RSpec.describe InstagramAccounts::StoryReplyResendService do
  it "resends story reply using saved archive context" do
    account = InstagramAccount.create!(username: "acct_#{SecureRandom.hex(4)}")
    profile = account.instagram_profiles.create!(username: "profile_#{SecureRandom.hex(3)}", ig_user_id: "ig_#{SecureRandom.hex(4)}")
    event = profile.instagram_profile_events.create!(
      kind: "story_downloaded",
      external_id: "story_downloaded:#{SecureRandom.hex(4)}",
      occurred_at: Time.current,
      detected_at: Time.current,
      metadata: { "story_id" => "1234567890", "reply_comment" => "Saved reply" }
    )
    event.media.attach(io: StringIO.new("story-bytes"), filename: "story.jpg", content_type: "image/jpeg")

    service = described_class.new(account: account, event_id: event.id, comment_text: nil)
    allow_any_instance_of(Messaging::IntegrationService).to receive(:send_text!).and_return(
      { ok: true, provider_message_id: "provider_#{SecureRandom.hex(3)}" }
    )

    result = service.call

    expect(result.status).to eq(:ok)
    expect(result.payload[:status]).to eq("sent")
    event.reload
    expect(event.metadata["reply_comment"]).to eq("Saved reply")
    expect(account.instagram_messages.where(status: "sent").count).to eq(1)
    expect(profile.instagram_profile_events.where(kind: "story_reply_resent").count).to eq(1)
  end

  it "records failed resend attempts without deleting story data" do
    account = InstagramAccount.create!(username: "acct_#{SecureRandom.hex(4)}")
    profile = account.instagram_profiles.create!(username: "profile_#{SecureRandom.hex(3)}")
    event = profile.instagram_profile_events.create!(
      kind: "story_downloaded",
      external_id: "story_downloaded:#{SecureRandom.hex(4)}",
      occurred_at: Time.current,
      detected_at: Time.current,
      metadata: { "story_id" => "99887766", "reply_comment" => "retry me" }
    )
    event.media.attach(io: StringIO.new("story-bytes"), filename: "story.jpg", content_type: "image/jpeg")

    service = described_class.new(account: account, event_id: event.id, comment_text: nil)
    allow_any_instance_of(Messaging::IntegrationService).to receive(:send_text!).and_raise("API failure")

    result = service.call

    expect(result.status).to eq(:unprocessable_entity)
    event.reload
    expect(event.media).to be_attached
    expect(account.instagram_messages.where(status: "failed").count).to eq(1)
    expect(profile.instagram_profile_events.where(kind: "story_reply_resend_failed").count).to eq(1)
  end
end
