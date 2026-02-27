require "rails_helper"
require "securerandom"

RSpec.describe Pipeline::SequentialProcessingGate do
  let(:account) { InstagramAccount.create!(username: "acct_#{SecureRandom.hex(4)}") }

  it "returns an unblocked snapshot when no work is pending" do
    snapshot = described_class.new(account: account).snapshot

    expect(snapshot[:blocked]).to eq(false)
    expect(snapshot[:blocking_reasons]).to eq([])
    expect(snapshot[:blocking_counts]).to include(
      story_events_pending: 0,
      posts_pending: 0,
      workspace_items_pending: 0
    )
  end

  it "blocks when story/post/workspace rows are pending" do
    profile = account.instagram_profiles.create!(username: "person_#{SecureRandom.hex(4)}")
    event = profile.record_event!(kind: "story_downloaded", external_id: "story_#{SecureRandom.hex(4)}")
    event.update!(llm_comment_status: "queued")

    profile.instagram_profile_posts.create!(
      instagram_account: account,
      shortcode: "pending_#{SecureRandom.hex(3)}",
      ai_status: "pending",
      metadata: { "workspace_actions" => { "status" => "running" } }
    )

    snapshot = described_class.new(account: account).snapshot

    expect(snapshot[:blocked]).to eq(true)
    expect(snapshot[:blocking_reasons]).to include(
      "story_pipeline_pending",
      "post_pipeline_pending",
      "workspace_items_pending"
    )
  end

  it "blocks when lifecycle rows show active story/feed/workspace jobs" do
    now = Time.current
    BackgroundJobLifecycle.create!(
      active_job_id: "story_#{SecureRandom.hex(3)}",
      job_class: "SyncHomeStoryCarouselJob",
      queue_name: "home_story_sync",
      status: "queued",
      instagram_account_id: account.id,
      last_transition_at: now
    )
    BackgroundJobLifecycle.create!(
      active_job_id: "feed_#{SecureRandom.hex(3)}",
      job_class: "CaptureHomeFeedJob",
      queue_name: "sync",
      status: "running",
      instagram_account_id: account.id,
      last_transition_at: now
    )
    BackgroundJobLifecycle.create!(
      active_job_id: "workspace_#{SecureRandom.hex(3)}",
      job_class: "WorkspaceProcessActionsTodoPostJob",
      queue_name: "workspace_actions_queue",
      status: "queued",
      instagram_account_id: account.id,
      last_transition_at: now
    )

    snapshot = described_class.new(account: account).snapshot

    expect(snapshot[:blocked]).to eq(true)
    expect(snapshot[:blocking_reasons]).to include(
      "story_jobs_active",
      "feed_jobs_active",
      "workspace_jobs_active"
    )
  end
end
