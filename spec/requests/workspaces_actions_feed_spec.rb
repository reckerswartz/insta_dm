require "rails_helper"
require "securerandom"

RSpec.describe "WorkspacesActionsFeed", type: :request do
  it "uses read-only queue refresh for polling endpoint" do
    account = InstagramAccount.create!(username: "acct_#{SecureRandom.hex(4)}")
    service = instance_double(Workspace::ActionsTodoQueueService, fetch!: { items: [], stats: {} })

    expect(Workspace::ActionsTodoQueueService).to receive(:new).with(
      account: account,
      limit: WorkspacesController::DEFAULT_QUEUE_LIMIT,
      enqueue_processing: false
    ).and_return(service)

    get actions_feed_workspace_path

    expect(response).to have_http_status(:ok)
  end

  it "keeps enqueueing enabled for initial workspace page load" do
    account = InstagramAccount.create!(username: "acct_#{SecureRandom.hex(4)}")
    service = instance_double(Workspace::ActionsTodoQueueService, fetch!: { items: [], stats: {} })

    expect(Workspace::ActionsTodoQueueService).to receive(:new).with(
      account: account,
      limit: WorkspacesController::DEFAULT_QUEUE_LIMIT,
      enqueue_processing: true
    ).and_return(service)

    get actions_workspace_path

    expect(response).to have_http_status(:ok)
  end
end
