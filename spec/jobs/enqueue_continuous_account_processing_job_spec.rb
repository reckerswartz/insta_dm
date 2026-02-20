require "rails_helper"
require "securerandom"

RSpec.describe "EnqueueContinuousAccountProcessingJobTest" do
  include ActiveJob::TestHelper

  before do
    clear_enqueued_jobs
    clear_performed_jobs
  end

  def create_continuous_account
    account = InstagramAccount.create!(
      username: "acct_#{SecureRandom.hex(4)}",
      continuous_processing_enabled: true
    )
    account.update!(cookies: [ { "name" => "sessionid", "value" => SecureRandom.hex(8) } ])
    account
  end

  it "splits scheduler fan-out across continuation jobs while respecting limit" do
    first = create_continuous_account
    second = create_continuous_account
    _third = create_continuous_account
    _fourth = create_continuous_account

    EnqueueContinuousAccountProcessingJob.perform_now(limit: 3, batch_size: 2)

    queued_processing_jobs = enqueued_jobs.select { |row| row[:job] == ProcessInstagramAccountContinuouslyJob }
    expect(queued_processing_jobs.length).to eq(2)

    continuation = enqueued_jobs.find { |row| row[:job] == EnqueueContinuousAccountProcessingJob }
    expect(continuation).to be_present
    continuation_args = Array(continuation[:args]).first.to_h.with_indifferent_access
    expect(continuation_args[:cursor_id]).to eq(second.id)
    expect(continuation_args[:remaining]).to eq(1)
    expect(continuation_args[:limit]).to eq(3)
    expect(continuation_args[:batch_size]).to eq(2)
  end
end
