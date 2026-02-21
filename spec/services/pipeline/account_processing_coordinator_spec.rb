require "rails_helper"
require "securerandom"

RSpec.describe Pipeline::AccountProcessingCoordinator do
  JobResult = Struct.new(:job_id, :queue_name)

  let(:account) { InstagramAccount.create!(username: "acct_#{SecureRandom.hex(4)}") }
  let(:now) { Time.utc(2026, 2, 20, 12, 0, 0) }

  before do
    allow(Ops::StructuredLogger).to receive(:info)
    allow(Ops::StructuredLogger).to receive(:warn)
  end

  it "enqueues all due work when local AI is healthy" do
    allow(Ops::LocalAiHealth).to receive(:check).and_return({ ok: true })

    allow(SyncHomeStoryCarouselJob).to receive(:perform_later).with(
      instagram_account_id: account.id,
      story_limit: SyncHomeStoryCarouselJob::STORY_BATCH_LIMIT,
      auto_reply_only: false
    ).and_return(JobResult.new("job-story", "home_story_sync"))

    allow(AutoEngageHomeFeedJob).to receive(:perform_later).with(
      instagram_account_id: account.id,
      max_posts: 2,
      include_story: false,
      story_hold_seconds: 18
    ).and_return(JobResult.new("job-feed", "engagements"))

    allow(EnqueueRecentProfilePostScansForAccountJob).to receive(:perform_later).with(
      instagram_account_id: account.id,
      limit_per_account: 6,
      posts_limit: 3,
      comments_limit: 8
    ).and_return(JobResult.new("job-scan", "post_downloads"))

    queue_service = instance_double(
      Workspace::ActionsTodoQueueService,
      fetch!: {
        stats: {
          enqueued_now: 2,
          ready_items: 3,
          processing_items: 1,
          total_items: 6
        }
      }
    )
    allow(Workspace::ActionsTodoQueueService).to receive(:new).with(
      account: account,
      limit: 40,
      enqueue_processing: true
    ).and_return(queue_service)

    coordinator = described_class.new(account: account, trigger_source: :scheduler, now: now)
    allow(coordinator).to receive(:rand).and_return(0)

    result = coordinator.run!

    expect(result[:trigger_source]).to eq("scheduler")
    expect(result[:local_ai_health]).to eq({ ok: true })
    expect(result[:skipped_jobs]).to eq([])

    enqueued_names = result[:enqueued_jobs].map { |row| row[:job] }
    expect(enqueued_names).to include(
      "SyncHomeStoryCarouselJob",
      "AutoEngageHomeFeedJob",
      "EnqueueRecentProfilePostScansForAccountJob",
      "Workspace::ActionsTodoQueueService"
    )

    workspace_row = result[:enqueued_jobs].find { |row| row[:job] == "Workspace::ActionsTodoQueueService" }
    expect(workspace_row[:queued_now]).to eq(2)
    expect(workspace_row[:total_items]).to eq(6)

    account.reload
    expect(account.continuous_processing_next_story_sync_at).to eq(now + described_class::STORY_SYNC_INTERVAL)
    expect(account.continuous_processing_next_feed_sync_at).to eq(now + described_class::FEED_SYNC_INTERVAL)
    expect(account.continuous_processing_next_profile_scan_at).to eq(now + described_class::PROFILE_SCAN_INTERVAL)
    expect(account.continuous_processing_last_heartbeat_at).to be_present
    expect(result[:finished_at]).to be_present
  end

  it "skips AI-dependent jobs and enqueues profile-refresh fallback when local AI is unhealthy" do
    allow(Ops::LocalAiHealth).to receive(:check).and_return({ ok: false })

    expect(SyncHomeStoryCarouselJob).not_to receive(:perform_later)
    expect(AutoEngageHomeFeedJob).not_to receive(:perform_later)
    expect(EnqueueRecentProfilePostScansForAccountJob).not_to receive(:perform_later)

    allow(SyncNextProfilesForAccountJob).to receive(:perform_later).with(
      instagram_account_id: account.id,
      limit: 10
    ).and_return(JobResult.new("job-refresh", "profiles"))

    queue_service = instance_double(
      Workspace::ActionsTodoQueueService,
      fetch!: { stats: { enqueued_now: 0, ready_items: 0, processing_items: 0, total_items: 0 } }
    )
    allow(Workspace::ActionsTodoQueueService).to receive(:new).and_return(queue_service)

    coordinator = described_class.new(account: account, trigger_source: "timer", now: now)
    allow(coordinator).to receive(:rand).and_return(0)

    result = coordinator.run!

    expect(result[:skipped_jobs]).to include(
      include(job: "SyncHomeStoryCarouselJob", reason: "local_ai_unhealthy"),
      include(job: "AutoEngageHomeFeedJob", reason: "local_ai_unhealthy")
    )

    enqueued_names = result[:enqueued_jobs].map { |row| row[:job] }
    expect(enqueued_names).to include("SyncNextProfilesForAccountJob", "Workspace::ActionsTodoQueueService")
    expect(enqueued_names).not_to include("EnqueueRecentProfilePostScansForAccountJob")

    account.reload
    expect(account.continuous_processing_next_profile_scan_at).to eq(now + described_class::FALLBACK_PROFILE_REFRESH_INTERVAL)
    expect(account.continuous_processing_next_story_sync_at).to be_nil
    expect(account.continuous_processing_next_feed_sync_at).to be_nil
  end

  it "records workspace refresh failure without aborting the run" do
    account.update!(
      continuous_processing_next_story_sync_at: now + 1.day,
      continuous_processing_next_feed_sync_at: now + 1.day,
      continuous_processing_next_profile_scan_at: now + 1.day
    )

    allow(Ops::LocalAiHealth).to receive(:check).and_return({ ok: true })
    allow(Workspace::ActionsTodoQueueService).to receive(:new).and_return(
      instance_double(Workspace::ActionsTodoQueueService).tap do |service|
        allow(service).to receive(:fetch!).and_raise(RuntimeError, "queue down")
      end
    )

    expect(SyncHomeStoryCarouselJob).not_to receive(:perform_later)
    expect(AutoEngageHomeFeedJob).not_to receive(:perform_later)
    expect(EnqueueRecentProfilePostScansForAccountJob).not_to receive(:perform_later)
    expect(SyncNextProfilesForAccountJob).not_to receive(:perform_later)

    coordinator = described_class.new(account: account, trigger_source: :heartbeat, now: now)
    allow(coordinator).to receive(:rand).and_return(0)

    result = coordinator.run!

    expect(result[:enqueued_jobs]).to eq([])
    expect(result[:skipped_jobs]).to include(
      include(
        job: "Workspace::ActionsTodoQueueService",
        reason: "workspace_queue_refresh_failed",
        error_class: "RuntimeError"
      )
    )

    expect(account.reload.continuous_processing_last_heartbeat_at).to be_present
  end
end
