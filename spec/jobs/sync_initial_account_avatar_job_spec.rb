require "rails_helper"
require "securerandom"

RSpec.describe SyncInitialAccountAvatarJob do
  include ActiveJob::TestHelper

  before do
    clear_enqueued_jobs
    clear_performed_jobs
  end

  def rate_limit_cache_key_for(account_id)
    "#{described_class::RATE_LIMIT_CACHE_KEY_PREFIX}:#{account_id}"
  end

  def rate_limit_store
    described_class.new.send(:rate_limit_store)
  end

  after do
    InstagramAccount.find_each do |account|
      rate_limit_store.delete(rate_limit_cache_key_for(account.id))
    end
  end

  it "creates the account profile and enqueues profile details fetch" do
    account = InstagramAccount.create!(username: "acct_bootstrap_#{SecureRandom.hex(4)}")
    fetch_job = instance_double(ActiveJob::Base, job_id: "fetch-job-1", queue_name: "profiles")
    allow(FetchInstagramProfileDetailsJob).to receive(:perform_later).and_return(fetch_job)

    described_class.perform_now(instagram_account_id: account.id)

    profile = account.reload.instagram_profiles.find_by(username: account.username)
    expect(profile).to be_present
    expect(FetchInstagramProfileDetailsJob).to have_received(:perform_later).with(
      instagram_account_id: account.id,
      instagram_profile_id: profile.id,
      profile_action_log_id: kind_of(Integer)
    )
    action_log = profile.instagram_profile_action_logs.order(id: :desc).first
    expect(action_log).to be_present
    expect(action_log.action).to eq("fetch_profile_details")
    expect(action_log.trigger_source).to eq("account_created_avatar_bootstrap")
    expect(action_log.active_job_id).to eq("fetch-job-1")
  end

  it "skips repeated bootstrap sync attempts within the rate-limit window" do
    account = InstagramAccount.create!(username: "acct_bootstrap_#{SecureRandom.hex(4)}")
    fetch_job = instance_double(ActiveJob::Base, job_id: "fetch-job-2", queue_name: "profiles")
    allow(FetchInstagramProfileDetailsJob).to receive(:perform_later).and_return(fetch_job)

    described_class.perform_now(instagram_account_id: account.id)
    described_class.perform_now(instagram_account_id: account.id)

    expect(FetchInstagramProfileDetailsJob).to have_received(:perform_later).once
  end

  it "releases the rate-limit reservation when enqueue fails" do
    account = InstagramAccount.create!(username: "acct_bootstrap_#{SecureRandom.hex(4)}")
    allow(FetchInstagramProfileDetailsJob).to receive(:perform_later).and_raise("transient enqueue failure")

    expect do
      described_class.perform_now(instagram_account_id: account.id)
    end.to raise_error(RuntimeError, "transient enqueue failure")

    fetch_job = instance_double(ActiveJob::Base, job_id: "fetch-job-3", queue_name: "profiles")
    allow(FetchInstagramProfileDetailsJob).to receive(:perform_later).and_return(fetch_job)

    expect do
      described_class.perform_now(instagram_account_id: account.id)
    end.not_to raise_error
  end
end
