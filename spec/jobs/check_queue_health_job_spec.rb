require "rails_helper"

RSpec.describe CheckQueueHealthJob, type: :job do
  before do
    Rails.cache.delete("ops:check_queue_health_job:last_checked_at")
    CheckQueueHealthJob.instance_variable_set(:@last_checked_at_fallback, nil)
  end

  it "runs queue health check once within throttle window" do
    allow(Ops::QueueHealth).to receive(:check!)

    described_class.perform_now
    described_class.perform_now

    expect(Ops::QueueHealth).to have_received(:check!).once
  end

  it "can be forced to bypass throttle" do
    allow(Ops::QueueHealth).to receive(:check!)

    described_class.perform_now
    described_class.perform_now(force: true)

    expect(Ops::QueueHealth).to have_received(:check!).twice
  end
end
