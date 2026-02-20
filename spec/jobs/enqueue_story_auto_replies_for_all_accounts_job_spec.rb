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
      force_analyze_all: true
    )

    account_jobs = enqueued_jobs.select { |row| row[:job] == SyncProfileStoriesForAccountJob }
    expect(account_jobs.length).to eq(2)

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
end
