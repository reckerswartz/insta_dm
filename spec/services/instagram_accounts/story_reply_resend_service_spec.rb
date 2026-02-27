require "rails_helper"
require "securerandom"
require "stringio"

RSpec.describe InstagramAccounts::StoryReplyResendService do
  def build_event(account:, metadata: {})
    profile = account.instagram_profiles.create!(username: "profile_#{SecureRandom.hex(3)}")
    event = profile.instagram_profile_events.create!(
      kind: "story_downloaded",
      external_id: "story_downloaded:#{SecureRandom.hex(4)}",
      occurred_at: Time.current,
      detected_at: Time.current,
      metadata: metadata
    )
    event.media.attach(io: StringIO.new("story-bytes"), filename: "story.jpg", content_type: "image/jpeg")
    [ profile, event ]
  end

  it "sends manual story reply through API and updates status to sent" do
    account = InstagramAccount.create!(username: "acct_#{SecureRandom.hex(4)}")
    profile, event = build_event(
      account: account,
      metadata: { "story_id" => "1234567890", "reply_comment" => "Saved reply" }
    )
    client = instance_double(Instagram::Client)
    allow(client).to receive(:story_reply_eligibility).and_return(
      { eligible: true, status: "eligible", reason_code: nil }
    )
    allow(client).to receive(:send_story_reply_via_api!).and_return(
      { posted: true, method: "api", api_thread_id: "thread_1", api_item_id: "item_1" }
    )
    allow(ActionCable.server).to receive(:broadcast)

    result = described_class.new(
      account: account,
      event_id: event.id,
      comment_text: nil,
      instagram_client: client
    ).call

    expect(result.status).to eq(:ok)
    expect(result.payload[:status]).to eq("sent")
    expect(result.payload[:message]).to eq("Comment sent successfully.")

    event.reload
    expect(event.metadata["manual_send_status"]).to eq("sent")
    expect(event.metadata["reply_comment"]).to eq("Saved reply")
    expect(event.metadata["manual_send_last_sent_at"]).to be_present
    expect(account.instagram_messages.where(status: "sent").count).to eq(1)
    expect(profile.instagram_profile_events.where(kind: "story_reply_resent").count).to eq(1)

    expect(ActionCable.server).to have_received(:broadcast).with(
      "story_reply_status_#{account.id}",
      hash_including(event_id: event.id, status: "sending")
    )
    expect(ActionCable.server).to have_received(:broadcast).with(
      "story_reply_status_#{account.id}",
      hash_including(event_id: event.id, status: "sent")
    )
  end

  it "marks story as expired/removed when eligibility check fails" do
    account = InstagramAccount.create!(username: "acct_#{SecureRandom.hex(4)}")
    profile, event = build_event(
      account: account,
      metadata: { "story_id" => "99887766", "reply_comment" => "retry me" }
    )
    client = instance_double(Instagram::Client)
    allow(client).to receive(:story_reply_eligibility).and_return(
      { eligible: false, status: "expired_removed", reason_code: "story_unavailable" }
    )
    allow(client).to receive(:send_story_reply_via_api!)
    allow(ActionCable.server).to receive(:broadcast)

    result = described_class.new(
      account: account,
      event_id: event.id,
      comment_text: nil,
      instagram_client: client
    ).call

    expect(result.status).to eq(:unprocessable_entity)
    expect(result.payload[:status]).to eq("expired_removed")
    expect(result.payload[:reason]).to eq("story_unavailable")

    event.reload
    expect(event.metadata["manual_send_status"]).to eq("expired_removed")
    expect(event.metadata["manual_send_reason"]).to eq("story_unavailable")
    expect(profile.instagram_profile_events.where(kind: "story_reply_resend_unavailable").count).to eq(1)
    expect(account.instagram_messages.where(status: "failed").count).to eq(0)
    expect(client).not_to have_received(:send_story_reply_via_api!)
  end

  it "does not mark as expired when lookup is ambiguous and story metadata is still active" do
    account = InstagramAccount.create!(username: "acct_#{SecureRandom.hex(4)}")
    profile, event = build_event(
      account: account,
      metadata: {
        "story_id" => "99887700",
        "reply_comment" => "retry me",
        "expiring_at" => 45.minutes.from_now.utc.iso8601
      }
    )
    client = instance_double(Instagram::Client)
    allow(client).to receive(:story_reply_eligibility).and_return(
      { eligible: false, status: "expired_removed", reason_code: "story_unavailable" }
    )
    allow(client).to receive(:send_story_reply_via_api!)
    allow(ActionCable.server).to receive(:broadcast)

    result = described_class.new(
      account: account,
      event_id: event.id,
      comment_text: nil,
      instagram_client: client
    ).call

    expect(result.status).to eq(:unprocessable_entity)
    expect(result.payload[:status]).to eq("failed")
    expect(result.payload[:reason]).to eq("story_unavailable")

    event.reload
    expect(event.metadata["manual_send_status"]).to eq("failed")
    expect(profile.instagram_profile_events.where(kind: "story_reply_resend_unavailable").count).to eq(0)
    expect(profile.instagram_profile_events.where(kind: "story_reply_resend_failed").count).to eq(1)
    expect(client).not_to have_received(:send_story_reply_via_api!)
  end

  it "continues manual send when story lookup status is unknown" do
    account = InstagramAccount.create!(username: "acct_#{SecureRandom.hex(4)}")
    _profile, event = build_event(
      account: account,
      metadata: { "story_id" => "66778899", "reply_comment" => "ship it" }
    )
    client = instance_double(Instagram::Client)
    allow(client).to receive(:story_reply_eligibility).and_return(
      { eligible: true, status: "unknown", reason_code: "story_lookup_unresolved" }
    )
    allow(client).to receive(:send_story_reply_via_api!).and_return(
      { posted: true, method: "api", api_thread_id: "thread_2", api_item_id: "item_2" }
    )
    allow(ActionCable.server).to receive(:broadcast)

    result = described_class.new(
      account: account,
      event_id: event.id,
      comment_text: nil,
      instagram_client: client
    ).call

    expect(result.status).to eq(:ok)
    expect(result.payload[:status]).to eq("sent")
    expect(client).to have_received(:send_story_reply_via_api!).with(
      hash_including(story_id: "66778899")
    )
  end

  it "normalizes composite story ids before eligibility checks and send" do
    account = InstagramAccount.create!(username: "acct_#{SecureRandom.hex(4)}")
    profile, event = build_event(
      account: account,
      metadata: { "story_id" => "44556677_123456", "reply_comment" => "normalized id" }
    )
    client = instance_double(Instagram::Client)
    expect(client).to receive(:story_reply_eligibility).with(
      username: profile.username.to_s,
      story_id: "44556677"
    ).and_return(
      { eligible: true, status: "eligible", reason_code: nil }
    )
    expect(client).to receive(:send_story_reply_via_api!).with(
      story_id: "44556677",
      story_username: profile.username.to_s,
      comment_text: "normalized id"
    ).and_return(
      { posted: true, method: "api", api_thread_id: "thread_3", api_item_id: "item_3" }
    )
    allow(ActionCable.server).to receive(:broadcast)

    result = described_class.new(
      account: account,
      event_id: event.id,
      comment_text: nil,
      instagram_client: client
    ).call

    expect(result.status).to eq(:ok)
    expect(result.payload[:status]).to eq("sent")
  end

  it "strips wrapping quotes and trailing punctuation before sending manual comment text" do
    account = InstagramAccount.create!(username: "acct_#{SecureRandom.hex(4)}")
    profile, event = build_event(
      account: account,
      metadata: { "story_id" => "77889900", "reply_comment" => "fallback" }
    )
    client = instance_double(Instagram::Client)
    allow(client).to receive(:story_reply_eligibility).and_return(
      { eligible: true, status: "eligible", reason_code: nil }
    )
    expect(client).to receive(:send_story_reply_via_api!).with(
      story_id: "77889900",
      story_username: profile.username.to_s,
      comment_text: "Manual text"
    ).and_return(
      { posted: true, method: "api", api_thread_id: "thread_4", api_item_id: "item_4" }
    )
    allow(ActionCable.server).to receive(:broadcast)

    result = described_class.new(
      account: account,
      event_id: event.id,
      comment_text: "\"Manual text\",",
      instagram_client: client
    ).call

    expect(result.status).to eq(:ok)
    expect(result.payload[:status]).to eq("sent")
  end

  it "does not resend when the same comment was already posted" do
    account = InstagramAccount.create!(username: "acct_#{SecureRandom.hex(4)}")
    profile, event = build_event(
      account: account,
      metadata: { "story_id" => "11223344", "reply_comment" => "Same text" }
    )
    profile.record_event!(
      kind: "story_reply_sent",
      external_id: "story_reply_sent:11223344",
      occurred_at: Time.current,
      metadata: { story_id: "11223344", reply_comment: "Same text" }
    )

    client = instance_double(Instagram::Client)
    allow(client).to receive(:story_reply_eligibility).and_return(
      { eligible: true, status: "eligible", reason_code: nil }
    )
    allow(client).to receive(:send_story_reply_via_api!)
    allow(ActionCable.server).to receive(:broadcast)

    result = described_class.new(
      account: account,
      event_id: event.id,
      comment_text: nil,
      instagram_client: client
    ).call

    expect(result.status).to eq(:ok)
    expect(result.payload[:status]).to eq("sent")
    expect(result.payload[:already_posted]).to eq(true)
    expect(client).not_to have_received(:send_story_reply_via_api!)

    event.reload
    expect(event.metadata["manual_send_status"]).to eq("sent")
    expect(event.metadata["manual_send_reason"]).to eq("already_posted")
    expect(account.instagram_messages.where(status: "sent").count).to eq(0)
    expect(profile.instagram_profile_events.where(kind: "story_reply_resent").count).to eq(0)
  end

  it "marks send as failed and keeps retry available when story API call fails" do
    account = InstagramAccount.create!(username: "acct_#{SecureRandom.hex(4)}")
    profile, event = build_event(
      account: account,
      metadata: { "story_id" => "55667788", "reply_comment" => "retry this comment" }
    )
    client = instance_double(Instagram::Client)
    allow(client).to receive(:story_reply_eligibility).and_return(
      { eligible: true, status: "eligible", reason_code: nil }
    )
    allow(client).to receive(:send_story_reply_via_api!).and_return(
      { posted: false, method: "api", reason: "api_status_fail" }
    )
    allow(ActionCable.server).to receive(:broadcast)

    result = described_class.new(
      account: account,
      event_id: event.id,
      comment_text: nil,
      instagram_client: client
    ).call

    expect(result.status).to eq(:unprocessable_entity)
    expect(result.payload[:status]).to eq("failed")
    expect(result.payload[:reason]).to eq("api_status_fail")

    event.reload
    expect(event.metadata["manual_send_status"]).to eq("failed")
    expect(event.metadata["manual_send_last_error"]).to include("api_status_fail")
    expect(account.instagram_messages.where(status: "failed").count).to eq(1)
    expect(profile.instagram_profile_events.where(kind: "story_reply_resend_failed").count).to eq(1)

    expect(ActionCable.server).to have_received(:broadcast).with(
      "story_reply_status_#{account.id}",
      hash_including(event_id: event.id, status: "failed")
    )
  end
end
