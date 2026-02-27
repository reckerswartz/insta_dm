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

  it "enqueues only story sync when all phases are due and AI is healthy" do
    allow(Ops::LocalAiHealth).to receive(:check).and_return({ ok: true })

    allow(SyncHomeStoryCarouselJob).to receive(:perform_later).with(
      instagram_account_id: account.id,
      story_limit: SyncHomeStoryCarouselJob::STORY_BATCH_LIMIT,
      auto_reply_only: false
    ).and_return(JobResult.new("job-story", "home_story_sync"))

    expect(CaptureHomeFeedJob).not_to receive(:perform_later)
    expect(EnqueueRecentProfilePostScansForAccountJob).not_to receive(:perform_later)
    expect(Workspace::ActionsTodoQueueService).not_to receive(:new)

    coordinator = described_class.new(account: account, trigger_source: :scheduler, now: now)
    allow(coordinator).to receive(:rand).and_return(0)

    result = coordinator.run!

    expect(result[:trigger_source]).to eq("scheduler")
    expect(result[:local_ai_health]).to eq({ ok: true })
    expect(result[:enqueued_jobs].map { |row| row[:job] }).to eq([ "SyncHomeStoryCarouselJob" ])
    expect(result[:skipped_jobs]).to include(
      include(job: "CaptureHomeFeedJob", reason: "higher_priority_phase_enqueued", blocking_phase: "story_sync"),
      include(job: "Workspace::ActionsTodoQueueService", reason: "higher_priority_phase_enqueued", blocking_phase: "story_sync"),
      include(job: "EnqueueRecentProfilePostScansForAccountJob", reason: "higher_priority_phase_enqueued", blocking_phase: "story_sync")
    )

    account.reload
    expect(account.continuous_processing_next_story_sync_at).to eq(now + described_class::STORY_SYNC_INTERVAL)
    expect(account.continuous_processing_next_feed_sync_at).to be_nil
    expect(account.continuous_processing_next_profile_scan_at).to be_nil
    expect(account.continuous_processing_last_heartbeat_at).to be_present
    expect(result[:finished_at]).to be_present
  end

  it "enqueues feed capture when story phase is not due" do
    account.update!(continuous_processing_next_story_sync_at: now + 1.day)
    allow(Ops::LocalAiHealth).to receive(:check).and_return({ ok: true })

    allow(CaptureHomeFeedJob).to receive(:perform_later).with(
      instagram_account_id: account.id,
      rounds: 3,
      delay_seconds: 20,
      max_new: 15,
      trigger_source: "scheduler"
    ).and_return(JobResult.new("job-feed", "engagements"))

    expect(SyncHomeStoryCarouselJob).not_to receive(:perform_later)
    expect(EnqueueRecentProfilePostScansForAccountJob).not_to receive(:perform_later)
    expect(Workspace::ActionsTodoQueueService).not_to receive(:new)

    coordinator = described_class.new(account: account, trigger_source: :scheduler, now: now)
    allow(coordinator).to receive(:rand).and_return(0)

    result = coordinator.run!

    expect(result[:enqueued_jobs].map { |row| row[:job] }).to eq([ "CaptureHomeFeedJob" ])
    expect(result[:skipped_jobs]).to include(
      include(job: "Workspace::ActionsTodoQueueService", reason: "higher_priority_phase_enqueued", blocking_phase: "feed_sync"),
      include(job: "EnqueueRecentProfilePostScansForAccountJob", reason: "higher_priority_phase_enqueued", blocking_phase: "feed_sync")
    )

    account.reload
    expect(account.continuous_processing_next_story_sync_at).to eq(now + 1.day)
    expect(account.continuous_processing_next_feed_sync_at).to eq(now + described_class::FEED_SYNC_INTERVAL)
    expect(account.continuous_processing_next_profile_scan_at).to be_nil
  end

  it "defers enqueues while account backlog is still pending" do
    profile = account.instagram_profiles.create!(username: "person_#{SecureRandom.hex(4)}")
    profile.instagram_profile_posts.create!(
      instagram_account: account,
      shortcode: "pending_#{SecureRandom.hex(3)}",
      ai_status: "pending"
    )

    allow(Ops::LocalAiHealth).to receive(:check).and_return({ ok: true })
    expect(SyncHomeStoryCarouselJob).not_to receive(:perform_later)
    expect(CaptureHomeFeedJob).not_to receive(:perform_later)
    expect(EnqueueRecentProfilePostScansForAccountJob).not_to receive(:perform_later)
    expect(Workspace::ActionsTodoQueueService).not_to receive(:new)

    coordinator = described_class.new(account: account, trigger_source: :scheduler, now: now)
    result = coordinator.run!

    expect(result[:enqueued_jobs]).to eq([])
    expect(result.dig(:priority_gate, :blocked)).to eq(true)
    expect(result[:skipped_jobs]).to include(
      include(job: "SyncHomeStoryCarouselJob", reason: "pending_backlog"),
      include(job: "CaptureHomeFeedJob", reason: "pending_backlog"),
      include(job: "Workspace::ActionsTodoQueueService", reason: "pending_backlog"),
      include(job: "EnqueueRecentProfilePostScansForAccountJob", reason: "pending_backlog")
    )
  end

  it "enqueues profile-refresh fallback when only profile scan is due and AI is unhealthy" do
    account.update!(
      continuous_processing_next_story_sync_at: now + 1.day,
      continuous_processing_next_feed_sync_at: now + 1.day
    )
    allow(Ops::LocalAiHealth).to receive(:check).and_return({ ok: false })

    queue_service = instance_double(
      Workspace::ActionsTodoQueueService,
      fetch!: { stats: { enqueued_now: 0, ready_items: 0, processing_items: 0, total_items: 0 } }
    )
    allow(Workspace::ActionsTodoQueueService).to receive(:new).and_return(queue_service)

    allow(SyncNextProfilesForAccountJob).to receive(:perform_later).with(
      instagram_account_id: account.id,
      limit: 10
    ).and_return(JobResult.new("job-refresh", "profiles"))

    expect(SyncHomeStoryCarouselJob).not_to receive(:perform_later)
    expect(CaptureHomeFeedJob).not_to receive(:perform_later)
    expect(EnqueueRecentProfilePostScansForAccountJob).not_to receive(:perform_later)

    coordinator = described_class.new(account: account, trigger_source: "timer", now: now)
    allow(coordinator).to receive(:rand).and_return(0)

    result = coordinator.run!

    expect(result[:enqueued_jobs].map { |row| row[:job] }).to contain_exactly(
      "Workspace::ActionsTodoQueueService",
      "SyncNextProfilesForAccountJob"
    )

    account.reload
    expect(account.continuous_processing_next_profile_scan_at).to eq(now + described_class::FALLBACK_PROFILE_REFRESH_INTERVAL)
    expect(account.continuous_processing_next_story_sync_at).to eq(now + 1.day)
    expect(account.continuous_processing_next_feed_sync_at).to eq(now + 1.day)
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
    expect(CaptureHomeFeedJob).not_to receive(:perform_later)
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
