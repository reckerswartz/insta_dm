require "rails_helper"
require "securerandom"
require "stringio"

RSpec.describe SendStoryReplyEngagementJob do
  def build_event
    account = InstagramAccount.create!(username: "acct_engage_#{SecureRandom.hex(3)}")
    profile = account.instagram_profiles.create!(username: "profile_engage_#{SecureRandom.hex(3)}")
    event = profile.instagram_profile_events.create!(
      kind: "story_downloaded",
      external_id: "story_downloaded:#{SecureRandom.hex(4)}",
      detected_at: Time.current,
      metadata: { "story_id" => "12345678", "reply_comment" => "Looks awesome" }
    )
    event.media.attach(io: StringIO.new("img"), filename: "story.jpg", content_type: "image/jpeg")
    [account, event]
  end

  it "delegates send flow to StoryReplyResendService on engagement queue" do
    account, event = build_event
    service = instance_double(
      InstagramAccounts::StoryReplyResendService,
      call: InstagramAccounts::StoryReplyResendService::Result.new(payload: { status: "sent" }, status: :ok)
    )
    allow(InstagramAccounts::StoryReplyResendService).to receive(:new).and_return(service)

    described_class.perform_now(
      instagram_account_id: account.id,
      event_id: event.id,
      comment_text: "Looks awesome",
      requested_by: "spec"
    )

    expect(InstagramAccounts::StoryReplyResendService).to have_received(:new).with(
      account: account,
      event_id: event.id,
      comment_text: "Looks awesome"
    )
    expect(service).to have_received(:call).once
  end

  it "requeues when engagement throttle window is active" do
    account, event = build_event
    allow(Rails.cache).to receive(:read).and_return(Time.current)
    allow(Rails.cache).to receive(:write)
    allow(described_class).to receive(:set).and_return(described_class)
    allow(described_class).to receive(:perform_later)
    allow(InstagramAccounts::StoryReplyResendService).to receive(:new)

    described_class.perform_now(
      instagram_account_id: account.id,
      event_id: event.id,
      comment_text: "Looks awesome",
      requested_by: "spec"
    )

    expect(described_class).to have_received(:set).once
    expect(described_class).to have_received(:perform_later).once
    expect(InstagramAccounts::StoryReplyResendService).not_to have_received(:new)
    expect(event.reload.metadata["manual_send_status"]).to eq("queued")
  end
end
