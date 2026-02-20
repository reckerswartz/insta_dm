require "rails_helper"
require "securerandom"

RSpec.describe InstagramAccounts::DashboardSnapshotService do
  let(:account) { InstagramAccount.create!(username: "acct_#{SecureRandom.hex(4)}") }

  it "assembles dashboard payload from collaborators" do
    sync_run = account.sync_runs.create!(status: "ok")
    failure = BackgroundJobFailure.create!(
      active_job_id: SecureRandom.uuid,
      queue_name: "default",
      job_class: "TestJob",
      arguments_json: "[]",
      error_class: "RuntimeError",
      error_message: "boom",
      failure_kind: "runtime",
      retryable: true,
      occurred_at: Time.current,
      instagram_account_id: account.id
    )
    queue_summary = { items: [ { id: 1 } ], stats: { total_items: 1 } }
    skip_summary = { window_hours: 72, total: 0, by_reason: [] }
    actions_service = instance_double(Workspace::ActionsTodoQueueService, fetch!: queue_summary)
    skip_service = instance_double(InstagramAccounts::SkipDiagnosticsService, call: skip_summary)

    allow(Ops::AccountIssues).to receive(:for).with(account).and_return([ { code: "x" } ])
    allow(Ops::Metrics).to receive(:for_account).with(account).and_return({ "cpu" => 2 })
    allow(Ops::AuditLogBuilder).to receive(:for_account).with(instagram_account: account, limit: 120).and_return([ { type: "event" } ])
    allow(Workspace::ActionsTodoQueueService).to receive(:new).with(account: account, limit: 20, enqueue_processing: true).and_return(actions_service)
    allow(InstagramAccounts::SkipDiagnosticsService).to receive(:new).with(account: account, hours: 72).and_return(skip_service)

    result = described_class.new(account: account).call

    expect(result[:issues]).to eq([ { code: "x" } ])
    expect(result[:metrics]).to eq({ "cpu" => 2 })
    expect(result[:latest_sync_run]).to eq(sync_run)
    expect(result[:recent_failures].map(&:id)).to eq([failure.id])
    expect(result[:recent_audit_entries]).to eq([ { type: "event" } ])
    expect(result[:actions_todo_queue]).to eq(queue_summary)
    expect(result[:skip_diagnostics]).to eq(skip_summary)
  end

  it "returns a safe empty queue summary when queue service fails" do
    actions_service = instance_double(Workspace::ActionsTodoQueueService)
    allow(actions_service).to receive(:fetch!).and_raise("queue_down")

    allow(Ops::AccountIssues).to receive(:for).and_return([])
    allow(Ops::Metrics).to receive(:for_account).and_return({})
    allow(Ops::AuditLogBuilder).to receive(:for_account).and_return([])
    allow(InstagramAccounts::SkipDiagnosticsService).to receive(:new).and_return(instance_double(InstagramAccounts::SkipDiagnosticsService, call: { window_hours: 72, total: 0, by_reason: [] }))
    allow(Workspace::ActionsTodoQueueService).to receive(:new).and_return(actions_service)

    result = described_class.new(account: account).call

    expect(result[:actions_todo_queue][:items]).to eq([])
    expect(result[:actions_todo_queue][:stats][:error]).to eq("queue_down")
  end
end
