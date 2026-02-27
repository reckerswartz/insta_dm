require "rails_helper"
require "securerandom"

RSpec.describe "EnqueueStoryAutoRepliesForAllAccountsJobTest" do
  include ActiveJob::TestHelper

  before do
    clear_enqueued_jobs
    clear_performed_jobs
  end

  def create_account_with_session
    account = InstagramAccount.create!(username: "acct_#{SecureRandom.hex(4)}")
    account.update!(cookies: [ { "name" => "sessionid", "value" => SecureRandom.hex(8) } ])
    account
  end

  it "enqueues account-level story sync jobs in batches" do
    first = create_account_with_session
    second = create_account_with_session
    third = create_account_with_session

    EnqueueStoryAutoRepliesForAllAccountsJob.perform_now(
      batch_size: 2,
      profile_limit: 5,
      max_stories: 4,
      force_analyze_all: true,
      cursor_id: first.id - 1
    )

    account_jobs = enqueued_jobs.select { |row| row[:job] == SyncProfileStoriesForAccountJob }
    expect(account_jobs.length).to eq(2)
    expect(account_jobs.first[:at]).to be_nil
    expect(account_jobs.second[:at]).to be_present

    account_ids = account_jobs.map do |row|
      args = Array(row[:args]).first.to_h.with_indifferent_access
      expect(args[:story_limit]).to eq(5)
      expect(args[:stories_per_profile]).to eq(4)
      expect(args[:with_comments]).to eq(true)
      expect(args[:require_auto_reply_tag]).to eq(true)
      expect(args[:force_analyze_all]).to eq(true)
      args[:instagram_account_id]
    end
    expect(account_ids).to contain_exactly(first.id, second.id)
    expect(account_ids).not_to include(third.id)

    continuation = enqueued_jobs.find { |row| row[:job] == EnqueueStoryAutoRepliesForAllAccountsJob }
    expect(continuation).to be_present
    continuation_args = Array(continuation[:args]).first.to_h.with_indifferent_access
    expect(continuation_args[:cursor_id]).to eq(second.id)
  end

  it "does not skip accounts when only post/workspace backlog is pending" do
    account = create_account_with_session
    profile = account.instagram_profiles.create!(username: "person_#{SecureRandom.hex(4)}")
    profile.instagram_profile_posts.create!(
      instagram_account: account,
      shortcode: "pending_#{SecureRandom.hex(3)}",
      ai_status: "pending"
    )

    result = EnqueueStoryAutoRepliesForAllAccountsJob.perform_now(
      batch_size: 1,
      profile_limit: 5,
      max_stories: 4,
      force_analyze_all: false,
      cursor_id: account.id - 1
    )

    account_jobs = enqueued_jobs.select { |row| row[:job] == SyncProfileStoriesForAccountJob }
    expect(account_jobs.length).to eq(1)
    expect(result[:backlog_skipped]).to eq(0)
  end

  it "skips accounts when story backlog is pending" do
    account = create_account_with_session
    profile = account.instagram_profiles.create!(username: "person_#{SecureRandom.hex(4)}")
    event = profile.record_event!(kind: "story_downloaded", external_id: "story_#{SecureRandom.hex(4)}")
    event.update!(llm_comment_status: "queued")

    result = EnqueueStoryAutoRepliesForAllAccountsJob.perform_now(
      batch_size: 1,
      profile_limit: 5,
      max_stories: 4,
      force_analyze_all: false,
      cursor_id: account.id - 1
    )

    account_jobs = enqueued_jobs.select { |row| row[:job] == SyncProfileStoriesForAccountJob }
    expect(account_jobs).to eq([])
    expect(result[:backlog_skipped]).to eq(1)
  end

  it "supports comment-prep mode without auto reply delivery" do
    account = create_account_with_session

    EnqueueStoryAutoRepliesForAllAccountsJob.perform_now(
      batch_size: 1,
      profile_limit: 1,
      max_stories: 10,
      auto_reply: false,
      require_auto_reply_tag: false
    )

    account_jobs = enqueued_jobs.select { |row| row[:job] == SyncProfileStoriesForAccountJob }
    expect(account_jobs.length).to eq(1)

    args = Array(account_jobs.first[:args]).first.to_h.with_indifferent_access
    expect(args[:instagram_account_id]).to eq(account.id)
    expect(args[:story_limit]).to eq(1)
    expect(args[:stories_per_profile]).to eq(10)
    expect(args[:with_comments]).to eq(false)
    expect(args[:require_auto_reply_tag]).to eq(false)
  end
end
