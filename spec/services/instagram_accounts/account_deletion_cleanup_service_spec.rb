require "rails_helper"
require "securerandom"

RSpec.describe InstagramAccounts::AccountDeletionCleanupService do
  it "removes sidekiq queued jobs that belong to the deleted account" do
    account = InstagramAccount.create!(username: "cleanup_queue_#{SecureRandom.hex(4)}")
    other_account = InstagramAccount.create!(username: "cleanup_queue_other_#{SecureRandom.hex(4)}")

    matching_entry = instance_double(
      "SidekiqEntry",
      item: wrapped_sidekiq_item(account_id: account.id),
      delete: true
    )
    non_matching_entry = instance_double(
      "SidekiqEntry",
      item: wrapped_sidekiq_item(account_id: other_account.id),
      delete: true
    )

    queue_entries = [ matching_entry, non_matching_entry ]
    allow(Sidekiq::Queue).to receive(:all).and_return([ queue_entries ])
    allow(Sidekiq::ScheduledSet).to receive(:new).and_return([])
    allow(Sidekiq::RetrySet).to receive(:new).and_return([])
    allow(Sidekiq::DeadSet).to receive(:new).and_return([])
    allow(Sidekiq::Workers).to receive(:new).and_return([])
    allow(Rails.application.config.active_job).to receive(:queue_adapter).and_return(:sidekiq)
    allow(Ops::BackgroundJobLifecycleRecorder).to receive(:record_sidekiq_removal)

    service = described_class.new(account: account)
    allow(service).to receive(:purge_account_storage!).and_return(true)
    allow(service).to receive(:delete_account_observability_rows!).and_return(true)

    service.call

    expect(matching_entry).to have_received(:delete).once
    expect(non_matching_entry).not_to have_received(:delete)
  end

  it "aborts account deletion cleanup if running sidekiq jobs are still active" do
    account = InstagramAccount.create!(username: "cleanup_running_#{SecureRandom.hex(4)}")

    running_payload = { "payload" => wrapped_sidekiq_item(account_id: account.id) }
    workers = [ [ "process-1", "thread-1", running_payload ] ]

    allow(Sidekiq::Queue).to receive(:all).and_return([])
    allow(Sidekiq::ScheduledSet).to receive(:new).and_return([])
    allow(Sidekiq::RetrySet).to receive(:new).and_return([])
    allow(Sidekiq::DeadSet).to receive(:new).and_return([])
    allow(Sidekiq::Workers).to receive(:new).and_return(workers)
    allow(Rails.application.config.active_job).to receive(:queue_adapter).and_return(:sidekiq)

    stub_const("#{described_class}::RUNNING_JOB_WAIT_TIMEOUT", 0.seconds)
    stub_const("#{described_class}::RUNNING_JOB_WAIT_INTERVAL", 0.seconds)

    service = described_class.new(account: account)
    allow(service).to receive(:purge_account_storage!).and_return(true)
    allow(service).to receive(:delete_account_observability_rows!).and_return(true)

    expect { service.call }.to raise_error(
      described_class::CleanupError,
      /still running/
    )
  end

  def wrapped_sidekiq_item(account_id:)
    {
      "class" => "ActiveJob::QueueAdapters::SidekiqAdapter::JobWrapper",
      "jid" => "jid_#{SecureRandom.hex(6)}",
      "args" => [
        {
          "job_class" => "SyncHomeStoryCarouselJob",
          "job_id" => SecureRandom.uuid,
          "queue_name" => "home_story_sync",
          "arguments" => [
            {
              "instagram_account_id" => account_id
            }
          ]
        }
      ]
    }
  end
end
