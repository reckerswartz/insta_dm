require "rails_helper"
require "securerandom"

RSpec.describe ApplicationJob do
  it "records queued lifecycle metadata when a job is enqueued" do
    account = InstagramAccount.create!(username: "acct_queue_#{SecureRandom.hex(4)}")
    profile = account.instagram_profiles.create!(username: "profile_queue_#{SecureRandom.hex(4)}")

    stub_const("QueuedLifecycleProbeJob", Class.new(ApplicationJob) do
      queue_as :story_processing

      def perform(**_kwargs); end
    end)

    enqueued = QueuedLifecycleProbeJob.perform_later(
      instagram_account_id: account.id,
      instagram_profile_id: profile.id
    )

    lifecycle = BackgroundJobLifecycle.find_by(active_job_id: enqueued.job_id)
    expect(lifecycle).to be_present
    expect(lifecycle.status).to eq("queued")
    expect(lifecycle.queue_name).to eq("story_processing")
    expect(lifecycle.instagram_account_id).to eq(account.id)
    expect(lifecycle.instagram_profile_id).to eq(profile.id)
    expect(lifecycle.queued_at).to be_present
  end

  it "applies continuous-processing backoff when authentication is required" do
    account = InstagramAccount.create!(username: "acct_#{SecureRandom.hex(4)}")

    stub_const("AuthDiscardProbeJob", Class.new(ApplicationJob) do
      queue_as :default

      def perform(instagram_account_id:)
        raise Instagram::AuthenticationRequiredError, "Stored cookies are not authenticated. Re-run Manual Browser Login or import fresh cookies."
      end
    end)

    expect do
      AuthDiscardProbeJob.perform_now(instagram_account_id: account.id)
    end.not_to raise_error

    account.reload
    expect(account.continuous_processing_state).to eq("idle")
    expect(account.continuous_processing_failure_count.to_i).to eq(1)
    expect(account.continuous_processing_retry_after_at).to be_present
    expect(account.continuous_processing_retry_after_at).to be > Time.current
    expect(account.continuous_processing_last_error).to include("Instagram::AuthenticationRequiredError")

    lifecycle = BackgroundJobLifecycle.where(job_class: "AuthDiscardProbeJob").order(id: :desc).first
    expect(lifecycle).to be_present
    expect(lifecycle.status).to eq("discarded")
    expect(lifecycle.discarded_at).to be_present
    expect(lifecycle.instagram_account_id).to eq(account.id)
  end
end
