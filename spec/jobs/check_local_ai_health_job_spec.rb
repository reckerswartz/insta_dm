require "rails_helper"

RSpec.describe CheckLocalAiHealthJob, type: :job do
  before do
    Rails.cache.delete("ops:check_local_ai_health_job:last_checked_at")
    Rails.cache.delete("ops:check_ai_microservice_health_job:last_checked_at")
    CheckLocalAiHealthJob.instance_variable_set(:@last_checked_at_fallback, nil)
  end

  it "throttles repeated checks inside the minimum interval" do
    allow(Ops::LocalAiHealth).to receive(:check).and_return(ok: true)
    allow(Ops::IssueTracker).to receive(:record_ai_service_check!)

    described_class.perform_now
    described_class.perform_now

    expect(Ops::LocalAiHealth).to have_received(:check).once
    expect(Ops::IssueTracker).to have_received(:record_ai_service_check!).once
  end

  it "records failures and re-raises while still updating throttle state" do
    allow(Ops::LocalAiHealth).to receive(:check).and_raise(Timeout::Error.new("timed out"))
    allow(Ops::IssueTracker).to receive(:record_ai_service_check!)

    expect { described_class.perform_now }.to raise_error(Timeout::Error)
    expect(Ops::IssueTracker).to have_received(:record_ai_service_check!).with(
      hash_including(ok: false)
    )
  end
end
