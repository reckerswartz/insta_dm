require "rails_helper"
require "securerandom"

RSpec.describe Admin::BackgroundJobs::FailurePayloadBuilder do
  before do
    allow(Ops::LiveUpdateBroadcaster).to receive(:broadcast!)
  end

  it "serializes failure rows with scope, context labels, and URLs" do
    account = InstagramAccount.create!(username: "acct_#{SecureRandom.hex(4)}")
    profile = account.instagram_profiles.create!(username: "profile_#{SecureRandom.hex(3)}")

    failure = BackgroundJobFailure.create!(
      active_job_id: SecureRandom.uuid,
      instagram_account_id: account.id,
      instagram_profile_id: profile.id,
      job_class: "AnalyzeInstagramProfileJob",
      queue_name: "profiles",
      error_class: "RuntimeError",
      error_message: "invalid payload",
      failure_kind: "runtime",
      retryable: true,
      occurred_at: Time.current,
      metadata: {}
    )

    payload = described_class.new(failures: [ failure ], total: 1, pages: 1).call

    expect(payload[:last_row]).to eq(1)
    expect(payload[:last_page]).to eq(1)

    row = payload[:data].first
    expect(row[:id]).to eq(failure.id)
    expect(row[:job_scope]).to eq("profile")
    expect(row[:context_label]).to eq("Profile ##{profile.id} (Account ##{account.id})")
    expect(row[:retryable]).to eq(true)
    expect(row[:open_url]).to include("/admin/background_jobs/failures/")
    expect(row[:retry_url]).to include("/admin/background_jobs/failures/#{failure.id}/retry")
  end

  it "marks authentication failures as not retryable now" do
    failure = BackgroundJobFailure.create!(
      active_job_id: SecureRandom.uuid,
      job_class: "SyncFollowGraphJob",
      queue_name: "sync",
      error_class: "AuthenticationError",
      error_message: "session expired",
      failure_kind: "authentication",
      retryable: true,
      occurred_at: Time.current,
      metadata: {}
    )

    payload = described_class.new(failures: [ failure ], total: 1, pages: 1).call

    expect(payload[:data].first[:job_scope]).to eq("system")
    expect(payload[:data].first[:retryable]).to eq(false)
  end
end
