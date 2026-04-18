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

RSpec.describe "rake jobs:purge_unresolvable", type: :task do
  require "rake"
  require "sidekiq/cron/job"
  require "sidekiq/api"

  before(:all) do
    Rails.application.load_tasks unless Rake::Task.task_defined?("jobs:purge_unresolvable")
  end

  around do |example|
    # ensure no lingering stale cron entries from earlier specs
    Sidekiq::Cron::Job.all.each { |j| j.destroy if j.name.to_s.start_with?("spec_purge_") }
    example.run
    Sidekiq::Cron::Job.all.each { |j| j.destroy if j.name.to_s.start_with?("spec_purge_") }
  end

  it "destroys cron entries whose class no longer exists" do
    created = Sidekiq::Cron::Job.create(
      name: "spec_purge_orphan_#{SecureRandom.hex(4)}",
      cron: "*/10 * * * *",
      klass: "ClassThatNoLongerExistsSpec_#{SecureRandom.hex(4)}"
    )
    expect(created).to be_truthy

    Rake::Task["jobs:purge_unresolvable"].reenable
    expect { Rake::Task["jobs:purge_unresolvable"].invoke }.to output(/Dropped 1 orphaned cron entry/).to_stdout

    expect(Sidekiq::Cron::Job.all.map(&:klass)).not_to include(a_string_starting_with("ClassThatNoLongerExistsSpec_"))
  end

  it "leaves cron entries pointing at live Active Job classes alone" do
    cron_name = "spec_purge_live_#{SecureRandom.hex(4)}"
    Sidekiq::Cron::Job.create(name: cron_name, cron: "*/10 * * * *", klass: "ApplicationJob")

    Rake::Task["jobs:purge_unresolvable"].reenable
    Rake::Task["jobs:purge_unresolvable"].invoke

    expect(Sidekiq::Cron::Job.all.map(&:name)).to include(cron_name)
  end

  it "sweeps BackgroundJobExecutionMetric rows whose job_class is no longer loadable" do
    orphan_class = "VanishedAnalyticsJob_#{SecureRandom.hex(4)}"
    live_class   = "ApplicationJob"

    3.times do
      BackgroundJobExecutionMetric.create!(
        active_job_id: SecureRandom.uuid,
        job_class: orphan_class,
        sidekiq_class: "ActiveJob::QueueAdapters::SidekiqAdapter::JobWrapper",
        sidekiq_jid: SecureRandom.hex(12),
        provider_job_id: SecureRandom.hex(12),
        queue_name: "maintenance",
        status: "failed",
        recorded_at: Time.current
      )
    end
    kept = BackgroundJobExecutionMetric.create!(
      active_job_id: SecureRandom.uuid,
      job_class: live_class,
      sidekiq_class: "ActiveJob::QueueAdapters::SidekiqAdapter::JobWrapper",
      sidekiq_jid: SecureRandom.hex(12),
      provider_job_id: SecureRandom.hex(12),
      queue_name: "default",
      status: "completed",
      recorded_at: Time.current
    )

    Rake::Task["jobs:purge_unresolvable"].reenable
    expect {
      Rake::Task["jobs:purge_unresolvable"].invoke
    }.to change {
      BackgroundJobExecutionMetric.where(job_class: orphan_class).count
    }.from(3).to(0)

    expect(BackgroundJobExecutionMetric.where(id: kept.id)).to exist
  end
end
