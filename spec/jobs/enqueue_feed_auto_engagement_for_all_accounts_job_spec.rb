require "rails_helper"
require "securerandom"

RSpec.describe "EnqueueFeedAutoEngagementForAllAccountsJobTest" do
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

  it "fans out in bounded account batches and enqueues continuation when needed" do
    first = create_account_with_session
    second = create_account_with_session
    third = create_account_with_session

    EnqueueFeedAutoEngagementForAllAccountsJob.perform_now(
      batch_size: 2,
      max_posts: 2,
      include_story: false,
      story_hold_seconds: 12,
      cursor_id: first.id - 1
    )

    enqueued_feed_jobs = enqueued_jobs.select { |row| row[:job] == AutoEngageHomeFeedJob }
    expect(enqueued_feed_jobs.length).to eq(2)

    continuation = enqueued_jobs.find { |row| row[:job] == EnqueueFeedAutoEngagementForAllAccountsJob }
    expect(continuation).to be_present
    continuation_args = Array(continuation[:args]).first.to_h.with_indifferent_access
    expect(continuation_args[:cursor_id]).to eq(second.id)
    expect(continuation_args[:batch_size]).to eq(2)
    expect(continuation_args[:max_posts]).to eq(2)
    expect(continuation_args[:include_story]).to eq(false)

    feed_account_ids = enqueued_feed_jobs.map do |row|
      Array(row[:args]).first.to_h.with_indifferent_access[:instagram_account_id]
    end
    expect(feed_account_ids).to contain_exactly(first.id, second.id)
    expect(feed_account_ids).not_to include(third.id)
  end

  it "skips accounts when the autonomous scheduler lease is already held" do
    first = create_account_with_session
    second = create_account_with_session
    third = create_account_with_session

    allow(AutonomousSchedulerLease).to receive(:reserve!).and_return(
      AutonomousSchedulerLease::Reservation.new(reserved: false, remaining_seconds: 45, blocked_by: "other_scheduler"),
      AutonomousSchedulerLease::Reservation.new(reserved: true, remaining_seconds: 0),
      AutonomousSchedulerLease::Reservation.new(reserved: true, remaining_seconds: 0)
    )

    result = EnqueueFeedAutoEngagementForAllAccountsJob.perform_now(
      batch_size: 3,
      max_posts: 2,
      include_story: false,
      story_hold_seconds: 12,
      cursor_id: first.id - 1
    )

    enqueued_feed_jobs = enqueued_jobs.select { |row| row[:job] == AutoEngageHomeFeedJob }
    enqueued_ids = enqueued_feed_jobs.map do |row|
      Array(row[:args]).first.to_h.with_indifferent_access[:instagram_account_id]
    end

    expect(result[:scheduler_lease_skipped]).to eq(1)
    expect(enqueued_ids).to contain_exactly(second.id, third.id)
  end
end
