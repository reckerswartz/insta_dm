require "rails_helper"
require "securerandom"

RSpec.describe InstagramAccount do
  include ActiveJob::TestHelper

  before do
    clear_enqueued_jobs
  end

  it "enqueues initial avatar sync after account creation" do
    expect do
      described_class.create!(username: "account_avatar_bootstrap_#{SecureRandom.hex(4)}")
    end.to have_enqueued_job(SyncInitialAccountAvatarJob)
  end

  it "deletes account-scoped records and purges linked storage on destroy" do
    account = described_class.create!(username: "account_cleanup_#{SecureRandom.hex(4)}")
    profile = account.instagram_profiles.create!(username: "profile_cleanup_#{SecureRandom.hex(4)}")

    profile.avatar.attach(
      io: StringIO.new("avatar-bytes"),
      filename: "avatar.jpg",
      content_type: "image/jpeg"
    )

    event = profile.instagram_profile_events.create!(
      kind: "story_downloaded",
      external_id: "story_downloaded:#{SecureRandom.hex(4)}",
      detected_at: Time.current
    )
    event.media.attach(
      io: StringIO.new("event-media"),
      filename: "event.jpg",
      content_type: "image/jpeg"
    )

    profile_post = account.instagram_profile_posts.create!(
      instagram_profile: profile,
      shortcode: "profile_post_#{SecureRandom.hex(4)}"
    )
    profile_post.media.attach(
      io: StringIO.new("profile-post-media"),
      filename: "profile_post.jpg",
      content_type: "image/jpeg"
    )

    story = account.instagram_stories.create!(
      instagram_profile: profile,
      story_id: "story_#{SecureRandom.hex(4)}",
      processing_status: "pending"
    )
    story.media.attach(
      io: StringIO.new("story-media"),
      filename: "story.jpg",
      content_type: "image/jpeg"
    )

    post = account.instagram_posts.create!(
      instagram_profile: profile,
      shortcode: "post_#{SecureRandom.hex(4)}",
      detected_at: Time.current,
      status: "captured"
    )
    post.media.attach(
      io: StringIO.new("post-media"),
      filename: "post.jpg",
      content_type: "image/jpeg"
    )

    BackgroundJobFailure.create!(
      active_job_id: SecureRandom.uuid,
      queue_name: "story_processing",
      job_class: "SyncInstagramProfileStoriesJob",
      error_class: "RuntimeError",
      error_message: "failure",
      failure_kind: "runtime",
      occurred_at: Time.current,
      instagram_account_id: account.id,
      instagram_profile_id: profile.id
    )
    BackgroundJobExecutionMetric.create!(
      active_job_id: SecureRandom.uuid,
      job_class: "SyncInstagramProfileStoriesJob",
      queue_name: "story_processing",
      status: "completed",
      recorded_at: Time.current,
      instagram_account_id: account.id,
      instagram_profile_id: profile.id
    )
    ServiceOutputAudit.create!(
      service_name: "spec_cleanup",
      status: "completed",
      recorded_at: Time.current,
      instagram_account_id: account.id,
      instagram_profile_id: profile.id
    )
    BackgroundJobLifecycle.create!(
      active_job_id: SecureRandom.uuid,
      job_class: "SyncInstagramProfileStoriesJob",
      queue_name: "story_processing",
      status: "queued",
      last_transition_at: Time.current,
      instagram_account_id: account.id,
      instagram_profile_id: profile.id
    )
    AppIssue.create!(
      issue_type: "job_failure",
      source: "jobs",
      title: "Cleanup issue",
      fingerprint: "cleanup_issue_#{SecureRandom.hex(6)}",
      severity: "error",
      status: "open",
      first_seen_at: Time.current,
      last_seen_at: Time.current,
      instagram_account_id: account.id,
      instagram_profile_id: profile.id
    )

    blob_ids = [
      profile.avatar.blob_id,
      event.media.blob_id,
      profile_post.media.blob_id,
      story.media.blob_id,
      post.media.blob_id
    ]

    expect(ActiveStorageIngestion.where(instagram_account_id: account.id)).to exist

    expect { account.destroy! }.to change(described_class, :count).by(-1)

    expect(InstagramProfile.where(instagram_account_id: account.id)).to be_empty
    expect(BackgroundJobFailure.where(instagram_account_id: account.id)).to be_empty
    expect(BackgroundJobExecutionMetric.where(instagram_account_id: account.id)).to be_empty
    expect(ServiceOutputAudit.where(instagram_account_id: account.id)).to be_empty
    expect(BackgroundJobLifecycle.where(instagram_account_id: account.id)).to be_empty
    expect(AppIssue.where(instagram_account_id: account.id)).to be_empty
    expect(ActiveStorageIngestion.where(instagram_account_id: account.id)).to be_empty
    expect(ActiveStorage::Attachment.where(blob_id: blob_ids)).to be_empty
    expect(ActiveStorage::Blob.where(id: blob_ids)).to be_empty
  end
end
