require "rails_helper"
require "securerandom"

RSpec.describe "CaptureHomeFeedJobTest" do
  it "skips execution when the account was captured too recently" do
    account = InstagramAccount.create!(
      username: "acct_#{SecureRandom.hex(4)}",
      continuous_processing_last_feed_sync_enqueued_at: Time.current
    )

    client = instance_double(Instagram::Client)
    allow(Instagram::Client).to receive(:new).with(account: account).and_return(client)
    allow(Ops::StructuredLogger).to receive(:info)
    expect(client).not_to receive(:capture_home_feed_posts!)

    CaptureHomeFeedJob.perform_now(
      instagram_account_id: account.id,
      rounds: 2,
      delay_seconds: 20,
      max_new: 10
    )
  end

  it "executes capture and stamps the account feed sync timestamp" do
    account = InstagramAccount.create!(username: "acct_#{SecureRandom.hex(4)}")
    now = Time.current
    account.update_columns(
      continuous_processing_last_feed_sync_enqueued_at: now - (CaptureHomeFeedJob::FEED_CAPTURE_MIN_INTERVAL_SECONDS + 60).seconds
    )

    client = instance_double(Instagram::Client)
    allow(Instagram::Client).to receive(:new).with(account: account).and_return(client)
    allow(client).to receive(:capture_home_feed_posts!).and_return(
      {
        seen_posts: 1,
        new_posts: 1,
        updated_posts: 0,
        queued_actions: 1,
        skipped_posts: 0,
        skipped_reasons: {}
      }
    )
    allow(Ops::StructuredLogger).to receive(:info)
    allow(Turbo::StreamsChannel).to receive(:broadcast_append_to)

    CaptureHomeFeedJob.perform_now(
      instagram_account_id: account.id,
      rounds: 2,
      delay_seconds: 20,
      max_new: 10
    )

    account.reload
    expect(account.continuous_processing_last_feed_sync_enqueued_at).to be_present
    expect(account.continuous_processing_last_feed_sync_enqueued_at).to be > now
    expect(client).to have_received(:capture_home_feed_posts!).with(rounds: 2, delay_seconds: 20, max_new: 10)
  end
end
