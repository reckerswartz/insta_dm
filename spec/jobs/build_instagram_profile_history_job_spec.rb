require "rails_helper"
require "securerandom"

RSpec.describe "BuildInstagramProfileHistoryJobTest" do
  include ActiveJob::TestHelper

  before do
    clear_enqueued_jobs
    clear_performed_jobs
  end

  def build_account_profile
    account = InstagramAccount.create!(username: "acct_#{SecureRandom.hex(4)}")
    profile = account.instagram_profiles.create!(
      username: "profile_#{SecureRandom.hex(4)}",
      display_name: "Profile User"
    )
    [ account, profile ]
  end

  it "requeues after a few hours when profile analysis is incomplete" do
    account, profile = build_account_profile
    log = profile.instagram_profile_action_logs.create!(
      instagram_account: account,
      action: "build_history",
      status: "queued",
      trigger_source: "rspec",
      occurred_at: Time.current
    )

    service_double = instance_double(Ai::ProfileHistoryBuildService)
    allow(Ai::ProfileHistoryBuildService).to receive(:new).and_return(service_double)
    allow(service_double).to receive(:execute!).and_return(
      {
        status: "pending",
        ready: false,
        reason_code: "latest_posts_not_analyzed",
        reason: "Latest posts not analyzed yet.",
        history_state: {
          "status" => "pending",
          "ready" => false,
          "reason_code" => "latest_posts_not_analyzed",
          "reason" => "Latest posts not analyzed yet."
        }
      }
    )

    BuildInstagramProfileHistoryJob.perform_now(
      instagram_account_id: account.id,
      instagram_profile_id: profile.id,
      profile_action_log_id: log.id,
      attempts: 0
    )

    log.reload
    expect(log.status).to eq("queued")
    expect(log.metadata.dig("retry", "queued")).to eq(true)
    expect(log.metadata.dig("retry", "next_run_at")).to be_present

    enqueued = enqueued_jobs.select { |row| row[:job] == BuildInstagramProfileHistoryJob }
    expect(enqueued.size).to be >= 1
  end

  it "marks action log succeeded when history is ready" do
    account, profile = build_account_profile
    log = profile.instagram_profile_action_logs.create!(
      instagram_account: account,
      action: "build_history",
      status: "queued",
      trigger_source: "rspec",
      occurred_at: Time.current
    )

    service_double = instance_double(Ai::ProfileHistoryBuildService)
    allow(Ai::ProfileHistoryBuildService).to receive(:new).and_return(service_double)
    allow(service_double).to receive(:execute!).and_return(
      {
        status: "ready",
        ready: true,
        reason_code: "history_ready",
        reason: "History ready.",
        history_state: {
          "status" => "ready",
          "ready" => true,
          "reason_code" => "history_ready",
          "reason" => "History ready."
        }
      }
    )

    BuildInstagramProfileHistoryJob.perform_now(
      instagram_account_id: account.id,
      instagram_profile_id: profile.id,
      profile_action_log_id: log.id,
      attempts: 1
    )

    log.reload
    expect(log.status).to eq("succeeded")
    expect(log.metadata["status"]).to eq("ready")
    expect(log.metadata["reason_code"]).to eq("history_ready")
  end
end
