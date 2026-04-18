require "rails_helper"
require "sidekiq"

RSpec.describe Ops::OrphanedJobClassMiddleware do
  let(:middleware) { described_class.new }
  let(:worker) { double("worker") }
  let(:queue) { "maintenance" }

  around do |example|
    original_count = BackgroundJobFailure.count
    example.run
    # sanity: spec should not leave extra rows beyond what it intends
    BackgroundJobFailure.where(failure_kind: "deprovisioned_class").delete_all if original_count == 0
  end

  def active_job_wrapper_msg(wrapped_class:, queue: "maintenance")
    {
      "class"   => "ActiveJob::QueueAdapters::SidekiqAdapter::JobWrapper",
      "wrapped" => wrapped_class,
      "queue"   => queue,
      "jid"     => "jid-#{SecureRandom.hex(6)}",
      "args"    => [ { "job_id" => SecureRandom.uuid, "arguments" => [] } ]
    }
  end

  it "swallows a NameError raised when wrapping a deleted job class and records a deprovisioned_class failure" do
    msg = active_job_wrapper_msg(wrapped_class: "ThisJobDoesNotExistAnywhere")

    expect do
      middleware.call(worker, msg, queue) { raise NameError, "uninitialized constant ThisJobDoesNotExistAnywhere" }
    end.to change { BackgroundJobFailure.where(failure_kind: "deprovisioned_class").count }.by(1)

    row = BackgroundJobFailure.where(failure_kind: "deprovisioned_class").order(:id).last
    expect(row.job_class).to eq("ThisJobDoesNotExistAnywhere")
    expect(row.queue_name).to eq(queue)
    expect(row.retryable).to eq(false)
    expect(row.error_class).to eq("NameError")
    expect(row.error_message).to include("ThisJobDoesNotExistAnywhere")
    expect(row.provider_job_id).to eq(msg["jid"])
  end

  it "re-raises NameError when the class IS loadable (real bug in the job body)" do
    msg = active_job_wrapper_msg(wrapped_class: "ApplicationJob")

    expect do
      middleware.call(worker, msg, queue) { raise NameError, "undefined method foo for object" }
    end.to raise_error(NameError)
    # No failure row should be created for the non-orphaned path — the real
    # error recorder owns that.
  end

  it "captures an ActiveJob::UnknownJobClassError directly and records a deprovisioned_class failure" do
    msg = active_job_wrapper_msg(wrapped_class: "ALongGoneJob")

    expect do
      middleware.call(worker, msg, queue) { raise ActiveJob::UnknownJobClassError, "Failed to instantiate job, class `ALongGoneJob` doesn't exist" }
    end.to change { BackgroundJobFailure.where(failure_kind: "deprovisioned_class").count }.by(1)

    row = BackgroundJobFailure.where(failure_kind: "deprovisioned_class").order(:id).last
    expect(row.error_class).to eq("ActiveJob::UnknownJobClassError")
  end
end
