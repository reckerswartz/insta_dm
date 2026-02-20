require "rails_helper"

RSpec.describe Admin::BackgroundJobs::RecentJobDetailsEnricher do
  it "attaches details to each row" do
    details_builder = instance_double(Admin::BackgroundJobs::JobDetailsBuilder)
    allow(details_builder).to receive(:call).and_return({ processing_steps: [ "ok" ] })

    rows = [
      {
        active_job_id: "job-1",
        status: "queued",
        queue_name: "default",
        class_name: "DemoJob"
      }
    ]

    result = described_class.new(rows: rows, details_builder: details_builder).call

    expect(result.first[:details]).to eq({ processing_steps: [ "ok" ] })
  end

  it "falls back gracefully when detail building raises" do
    details_builder = instance_double(Admin::BackgroundJobs::JobDetailsBuilder)
    allow(details_builder).to receive(:call).and_raise(StandardError, "boom")
    allow(details_builder).to receive(:fallback).and_return({ processing_steps: [ "fallback" ] })

    rows = [
      {
        active_job_id: nil,
        status: "queued",
        queue_name: "default",
        class_name: "DemoJob"
      }
    ]

    result = described_class.new(rows: rows, details_builder: details_builder).call

    expect(result.first[:details]).to eq({ processing_steps: [ "fallback" ] })
  end
end
