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
end
