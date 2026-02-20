require "rails_helper"
require "securerandom"

RSpec.describe "RecentFailureResilienceJobTest" do
  include ActiveJob::TestHelper

  before do
    clear_enqueued_jobs
    clear_performed_jobs
  end

  it "skips feed auto engagement when the account no longer exists" do
    expect(Instagram::Client).not_to receive(:new)

    expect do
      AutoEngageHomeFeedJob.perform_now(instagram_account_id: 99_999_999, max_posts: 2, include_story: false)
    end.not_to raise_error
  end

  it "skips account-level story sync when the account no longer exists" do
    expect(SyncInstagramProfileStoriesJob).not_to receive(:perform_later)

    expect do
      SyncProfileStoriesForAccountJob.perform_now(instagram_account_id: 99_999_999)
    end.not_to raise_error
  end

  it "skips continuous processing when the account no longer exists" do
    expect(Pipeline::AccountProcessingCoordinator).not_to receive(:new)

    expect do
      ProcessInstagramAccountContinuouslyJob.perform_now(instagram_account_id: 99_999_999)
    end.not_to raise_error
  end

  it "skips story processing when the story no longer exists" do
    expect(StoryProcessingService).not_to receive(:new)

    expect do
      StoryProcessingJob.perform_now(instagram_story_id: 99_999_999)
    end.not_to raise_error
  end

  it "falls back to split profile fetch + messageability when combined client method is unavailable" do
    account = InstagramAccount.create!(username: "acct_#{SecureRandom.hex(4)}")
    profile = account.instagram_profiles.create!(username: "profile_#{SecureRandom.hex(4)}", display_name: "Before")

    client_class = Class.new do
      attr_reader :fetched_usernames, :verified_usernames

      def initialize
        @fetched_usernames = []
        @verified_usernames = []
      end

      def fetch_profile_details!(username:)
        @fetched_usernames << username
        {
          display_name: "After",
          profile_pic_url: nil,
          ig_user_id: nil,
          bio: nil,
          followers_count: nil,
          last_post_at: nil
        }
      end

      def verify_messageability!(username:)
        @verified_usernames << username
        {
          can_message: true,
          restriction_reason: nil,
          dm_state: "messageable",
          dm_reason: nil,
          dm_retry_after_at: nil
        }
      end
    end
    client = client_class.new
    allow(Instagram::Client).to receive(:new).with(account: account).and_return(client)
    allow(Turbo::StreamsChannel).to receive(:broadcast_append_to)

    FetchInstagramProfileDetailsJob.perform_now(
      instagram_account_id: account.id,
      instagram_profile_id: profile.id
    )

    profile.reload
    expect(profile.display_name).to eq("After")
    expect(profile.can_message).to eq(true)
    expect(client.fetched_usernames).to eq([ profile.username ])
    expect(client.verified_usernames).to eq([ profile.username ])
  end

  it "skips profile details fetch when the account no longer exists" do
    expect(Instagram::Client).not_to receive(:new)

    expect do
      FetchInstagramProfileDetailsJob.perform_now(
        instagram_account_id: 99_999_999,
        instagram_profile_id: 99_999_998
      )
    end.not_to raise_error
  end

  it "skips profile history build when the account no longer exists" do
    expect(Ai::ProfileHistoryBuildService).not_to receive(:new)

    expect do
      BuildInstagramProfileHistoryJob.perform_now(
        instagram_account_id: 99_999_999,
        instagram_profile_id: 99_999_999
      )
    end.not_to raise_error
  end
end
