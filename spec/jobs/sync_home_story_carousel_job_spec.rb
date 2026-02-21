require "rails_helper"
require "securerandom"

RSpec.describe SyncHomeStoryCarouselJob do
  it "skips duplicate execution when account lock is not acquired" do
    account = InstagramAccount.create!(username: "story_lock_#{SecureRandom.hex(4)}")

    allow_any_instance_of(described_class).to receive(:claim_story_sync_lock!).and_return(false)
    expect(Instagram::Client).not_to receive(:new)
    allow(Ops::StructuredLogger).to receive(:info)

    described_class.perform_now(instagram_account_id: account.id, story_limit: 5)

    expect(Ops::StructuredLogger).to have_received(:info).with(
      hash_including(
        event: "story_sync.skipped_duplicate_execution",
        payload: hash_including(instagram_account_id: account.id)
      )
    )
  end

  it "releases the account lock after execution" do
    account = InstagramAccount.create!(username: "story_lock_#{SecureRandom.hex(4)}")
    client = instance_double(Instagram::Client)
    allow(Instagram::Client).to receive(:new).with(account: account).and_return(client)
    allow(client).to receive(:sync_home_story_carousel!).and_return(
      stories_visited: 1,
      failed: 0,
      downloaded: 1,
      analyzed: 0,
      commented: 0,
      reacted: 0,
      skipped_video: 0,
      skipped_ads: 0,
      skipped_invalid_media: 0,
      skipped_unreplyable: 0,
      skipped_interaction_retry: 0,
      skipped_reshared_external_link: 0,
      skipped_out_of_network: 0
    )

    allow(Turbo::StreamsChannel).to receive(:broadcast_append_to)
    allow_any_instance_of(described_class).to receive(:claim_story_sync_lock!).and_return(true)
    expect_any_instance_of(described_class).to receive(:release_story_sync_lock!).with(account_id: account.id)

    described_class.perform_now(instagram_account_id: account.id, story_limit: 1)
  end

  it "records the primary failure reason in action logs when sync completes with errors" do
    account = InstagramAccount.create!(username: "story_reason_#{SecureRandom.hex(4)}")
    client = instance_double(Instagram::Client)
    allow(Instagram::Client).to receive(:new).with(account: account).and_return(client)
    allow(client).to receive(:sync_home_story_carousel!).and_return(
      stories_visited: 0,
      failed: 2,
      downloaded: 0,
      analyzed: 0,
      commented: 0,
      reacted: 0,
      skipped_video: 0,
      skipped_ads: 0,
      skipped_invalid_media: 0,
      skipped_unreplyable: 0,
      skipped_interaction_retry: 0,
      skipped_reshared_external_link: 0,
      skipped_out_of_network: 0
    )
    allow_any_instance_of(described_class).to receive(:claim_story_sync_lock!).and_return(true)
    allow_any_instance_of(described_class).to receive(:recent_story_sync_failure_reasons).and_return(
      {
        "api_story_media_unavailable" => 2,
        "story_id_unresolved" => 1
      }
    )
    allow(Turbo::StreamsChannel).to receive(:broadcast_append_to)

    described_class.perform_now(instagram_account_id: account.id, story_limit: 10, auto_reply_only: false)

    profile = account.instagram_profiles.find_by(username: account.username)
    expect(profile).to be_present

    action_log = profile.instagram_profile_action_logs.where(action: "sync_stories_debug").order(id: :desc).first
    expect(action_log).to be_present
    expect(action_log.status).to eq("failed")
    expect(action_log.error_message).to include("reason=api_story_media_unavailable")
    expect(action_log.metadata["primary_failure_reason"]).to eq("api_story_media_unavailable")
    expect(action_log.metadata["failure_reasons"]).to include("api_story_media_unavailable" => 2)
  end

  it "records a sync failure event for audit visibility when the job errors early" do
    account = InstagramAccount.create!(username: "story_sync_fail_#{SecureRandom.hex(4)}")
    client = instance_double(Instagram::Client)
    allow(Instagram::Client).to receive(:new).with(account: account).and_return(client)
    allow(client).to receive(:sync_home_story_carousel!).and_raise(
      Instagram::AuthenticationRequiredError,
      "Stored cookies are not authenticated."
    )
    allow(Turbo::StreamsChannel).to receive(:broadcast_append_to)
    allow_any_instance_of(described_class).to receive(:claim_story_sync_lock!).and_return(true)

    described_class.perform_now(instagram_account_id: account.id, story_limit: 10, auto_reply_only: false)

    profile = account.instagram_profiles.find_by(username: account.username)
    expect(profile).to be_present

    failure_event = profile.instagram_profile_events.where(kind: "story_sync_job_failed").order(id: :desc).first
    expect(failure_event).to be_present
    expect(failure_event.metadata["source"]).to eq("home_story_carousel")
    expect(failure_event.metadata["reason"]).to eq("job_exception")
    expect(failure_event.metadata["error_class"]).to eq("Instagram::AuthenticationRequiredError")
    expect(failure_event.metadata["story_limit"]).to eq(10)
  end
end
