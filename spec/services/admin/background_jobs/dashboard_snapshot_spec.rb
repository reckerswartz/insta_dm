require "rails_helper"

RSpec.describe Admin::BackgroundJobs::DashboardSnapshot do
  it "returns a sidekiq-shaped snapshot" do
    snapshot = described_class.new(backend: "sidekiq").call

    expect(snapshot.backend).to eq("sidekiq")
    expect(snapshot.counts).to include(:enqueued, :scheduled, :retries, :dead, :processes, :queues)
    expect(snapshot.processes).to be_a(Array)
    expect(snapshot.recent_jobs).to be_a(Array)
    expect(snapshot.recent_failed).to be_a(Array)
  end

  it "returns a solid-queue-shaped snapshot for non-sidekiq backends" do
    snapshot = described_class.new(backend: "solid_queue").call

    expect(snapshot.backend).to eq("solid_queue")
    expect(snapshot.counts.keys).to include(:ready, :scheduled, :claimed, :blocked, :failed, :pauses, :jobs_total)
    expect(snapshot.processes).to be_a(Array)
    expect(snapshot.recent_jobs).to be_a(Array)
    expect(snapshot.recent_failed).to be_a(Array)
  end
end
