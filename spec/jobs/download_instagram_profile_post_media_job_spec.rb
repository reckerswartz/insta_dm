require "rails_helper"
require "securerandom"

RSpec.describe "DownloadInstagramProfilePostMediaJobTest" do
  include ActiveJob::TestHelper

  before do
    clear_enqueued_jobs
    clear_performed_jobs
  end

  it "reuses cached media and queues per-post analysis when profile is eligible" do
    source_account = InstagramAccount.create!(username: "src_acct_#{SecureRandom.hex(3)}")
    source_profile = source_account.instagram_profiles.create!(username: "src_profile_#{SecureRandom.hex(3)}")
    source_post = source_profile.instagram_profile_posts.create!(
      instagram_account: source_account,
      shortcode: "shared_shortcode_profile_1",
      source_media_url: "https://cdn.example.com/source.jpg",
      metadata: { "media_id" => "media_1", "media_type" => 1 }
    )
    source_post.media.attach(
      io: StringIO.new("cached-profile-media"),
      filename: "source.jpg",
      content_type: "image/jpeg"
    )

    account = InstagramAccount.create!(username: "dst_acct_#{SecureRandom.hex(3)}")
    profile = account.instagram_profiles.create!(username: "dst_profile_#{SecureRandom.hex(3)}", followers_count: 1500)
    post = profile.instagram_profile_posts.create!(
      instagram_account: account,
      shortcode: "shared_shortcode_profile_1",
      source_media_url: "https://cdn.example.com/new-signed.jpg?token=abc",
      metadata: { "media_id" => "media_1", "media_type" => 1 },
      ai_status: "failed"
    )

    assert_enqueued_with(job: AnalyzeInstagramProfilePostJob) do
      DownloadInstagramProfilePostMediaJob.perform_now(
        instagram_account_id: account.id,
        instagram_profile_id: profile.id,
        instagram_profile_post_id: post.id,
        trigger_analysis: true
      )
    end

    post.reload
    assert post.media.attached?
    assert_equal source_post.media.blob.id, post.media.blob.id
    assert_equal "downloaded", post.metadata["download_status"]
    assert_equal "local_cache", post.metadata["download_source"]
    assert_equal "pending", post.ai_status
    assert profile.instagram_profile_events.exists?(kind: "profile_post_media_downloaded")
    assert profile.instagram_profile_events.exists?(kind: "profile_post_analysis_queued")
  end

  it "skips analysis enqueue when profile policy blocks post analysis" do
    source_account = InstagramAccount.create!(username: "src_block_#{SecureRandom.hex(3)}")
    source_profile = source_account.instagram_profiles.create!(username: "src_block_profile_#{SecureRandom.hex(3)}")
    source_post = source_profile.instagram_profile_posts.create!(
      instagram_account: source_account,
      shortcode: "shared_shortcode_profile_2",
      source_media_url: "https://cdn.example.com/source-2.jpg",
      metadata: { "media_id" => "media_2", "media_type" => 1 }
    )
    source_post.media.attach(
      io: StringIO.new("cached-profile-media-2"),
      filename: "source2.jpg",
      content_type: "image/jpeg"
    )

    account = InstagramAccount.create!(username: "dst_block_#{SecureRandom.hex(3)}")
    profile = account.instagram_profiles.create!(username: "dst_block_profile_#{SecureRandom.hex(3)}", followers_count: 45_000)
    post = profile.instagram_profile_posts.create!(
      instagram_account: account,
      shortcode: "shared_shortcode_profile_2",
      source_media_url: "https://cdn.example.com/new-signed-2.jpg?token=xyz",
      metadata: { "media_id" => "media_2", "media_type" => 1 },
      ai_status: "pending"
    )

    assert_no_enqueued_jobs only: AnalyzeInstagramProfilePostJob do
      DownloadInstagramProfilePostMediaJob.perform_now(
        instagram_account_id: account.id,
        instagram_profile_id: profile.id,
        instagram_profile_post_id: post.id,
        trigger_analysis: true
      )
    end

    post.reload
    assert post.media.attached?
    assert_equal "downloaded", post.metadata["download_status"]
    assert_equal "analyzed", post.ai_status
    assert_not_nil post.analyzed_at
  end
end
