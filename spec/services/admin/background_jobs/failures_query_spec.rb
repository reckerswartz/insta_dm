require "rails_helper"
require "securerandom"

RSpec.describe Admin::BackgroundJobs::FailuresQuery do
  before do
    allow(Ops::LiveUpdateBroadcaster).to receive(:broadcast!)
  end

  it "applies tabulator filters, search, remote sorter, and pagination" do
    older = create_failure(
      job_class: "AnalyzeInstagramPostJob",
      queue_name: "profiles",
      error_class: "RuntimeError",
      error_message: "network timeout",
      occurred_at: 2.hours.ago,
      retryable: true
    )
    newer = create_failure(
      job_class: "AnalyzeInstagramPostJob",
      queue_name: "profiles",
      error_class: "RuntimeError",
      error_message: "network timeout while posting",
      occurred_at: 1.hour.ago,
      retryable: true
    )
    create_failure(
      job_class: "FetchInstagramProfileDetailsJob",
      queue_name: "default",
      error_class: "ArgumentError",
      error_message: "invalid state",
      occurred_at: 30.minutes.ago,
      retryable: false
    )

    params = ActionController::Parameters.new(
      filters: [
        { field: "job_class", value: "AnalyzeInstagramPost" },
        { field: "retryable", value: "true" }
      ].to_json,
      q: "timeout",
      sorters: [ { "field" => "occurred_at", "dir" => "asc" } ].to_json,
      per_page: 10,
      page: 1
    )

    result = described_class.new(params: params).call

    expect(result.total).to eq(2)
    expect(result.pages).to eq(1)
    expect(result.failures.map(&:id)).to eq([ older.id, newer.id ])
  end

  it "normalizes invalid page and per_page inputs" do
    create_failure(error_message: "first")
    create_failure(error_message: "second")

    params = ActionController::Parameters.new(page: -2, per_page: 0)
    result = described_class.new(params: params).call

    expect(result.total).to eq(2)
    expect(result.pages).to eq(1)
    expect(result.failures.length).to eq(2)
  end

  def create_failure(**attrs)
    defaults = {
      active_job_id: SecureRandom.uuid,
      job_class: "AnalyzeInstagramProfileJob",
      error_class: "RuntimeError",
      error_message: "boom",
      failure_kind: "runtime",
      occurred_at: Time.current,
      retryable: true,
      metadata: {}
    }

    BackgroundJobFailure.create!(defaults.merge(attrs))
  end
end
