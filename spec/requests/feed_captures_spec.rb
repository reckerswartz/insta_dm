require "rails_helper"
require "securerandom"

RSpec.describe "FeedCaptures", type: :request do
  before do
    FeedCaptureActivityLog.clear!
  end

  it "queues a feed capture job and reserves the throttle slot" do
    account = InstagramAccount.create!(username: "acct_#{SecureRandom.hex(4)}")

    expect do
      post feed_capture_path, params: { rounds: 4, delay_seconds: 45, max_new: 20 }
    end.to have_enqueued_job(CaptureHomeFeedJob).with(
      instagram_account_id: account.id,
      rounds: 4,
      delay_seconds: 45,
      max_new: 20,
      slot_claimed: true,
      trigger_source: "manual_feed_capture"
    )

    expect(response).to redirect_to(instagram_account_path(account))
    expect(account.reload.continuous_processing_last_feed_sync_enqueued_at).to be_present

    latest_entry = FeedCaptureActivityLog.entries_for(account: account, limit: 1).first
    expect(latest_entry).to be_present
    expect(latest_entry[:status]).to eq("queued")
  end

  it "does not enqueue duplicate feed capture while throttled" do
    account = InstagramAccount.create!(
      username: "acct_#{SecureRandom.hex(4)}",
      continuous_processing_last_feed_sync_enqueued_at: Time.current
    )

    expect do
      post feed_capture_path, params: { rounds: 4, delay_seconds: 45, max_new: 20 }
    end.not_to have_enqueued_job(CaptureHomeFeedJob)

    expect(response).to redirect_to(instagram_account_path(account))
    expect(flash[:alert]).to include("already queued or running")

    latest_entry = FeedCaptureActivityLog.entries_for(account: account, limit: 1).first
    expect(latest_entry).to be_present
    expect(latest_entry[:status]).to eq("skipped")
  end
end
