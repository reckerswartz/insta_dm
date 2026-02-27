require "rails_helper"
require "securerandom"

RSpec.describe "EnqueueRecentProfilePostScansForAllAccountsJobTest" do
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

  it "enqueues account-level profile scans in batches" do
    first = create_account_with_session
    second = create_account_with_session
    third = create_account_with_session

    EnqueueRecentProfilePostScansForAllAccountsJob.perform_now(
      batch_size: 2,
      limit_per_account: 6,
      posts_limit: 2,
      comments_limit: 7,
      cursor_id: first.id - 1
    )

    account_jobs = enqueued_jobs.select { |row| row[:job] == EnqueueRecentProfilePostScansForAccountJob }
    expect(account_jobs.length).to eq(2)
    expect(account_jobs.first[:at]).to be_nil
    expect(account_jobs.second[:at]).to be_present

    account_ids = account_jobs.map do |row|
      args = Array(row[:args]).first.to_h.with_indifferent_access
      expect(args[:limit_per_account]).to eq(6)
      expect(args[:posts_limit]).to eq(2)
      expect(args[:comments_limit]).to eq(7)
      args[:instagram_account_id]
    end
    expect(account_ids).to contain_exactly(first.id, second.id)
    expect(account_ids).not_to include(third.id)

    continuation = enqueued_jobs.find { |row| row[:job] == EnqueueRecentProfilePostScansForAllAccountsJob }
    expect(continuation).to be_present
    continuation_args = Array(continuation[:args]).first.to_h.with_indifferent_access
    expect(continuation_args[:cursor_id]).to eq(second.id)
  end

  it "skips accounts with pending backlog" do
    account = create_account_with_session
    profile = account.instagram_profiles.create!(username: "person_#{SecureRandom.hex(4)}")
    profile.instagram_profile_posts.create!(
      instagram_account: account,
      shortcode: "pending_#{SecureRandom.hex(3)}",
      ai_status: "pending"
    )

    result = EnqueueRecentProfilePostScansForAllAccountsJob.perform_now(
      batch_size: 1,
      limit_per_account: 4,
      posts_limit: 2,
      comments_limit: 6,
      cursor_id: account.id - 1
    )

    account_jobs = enqueued_jobs.select { |row| row[:job] == EnqueueRecentProfilePostScansForAccountJob }
    expect(account_jobs).to eq([])
    expect(result[:backlog_skipped]).to eq(1)
  end
end
