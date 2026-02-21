require "rails_helper"
require "securerandom"

RSpec.describe Instagram::Client do
  def stub_feed_capture_environment(client:, driver:)
    navigation = instance_double("SeleniumNavigation")
    allow(driver).to receive(:navigate).and_return(navigation)
    allow(navigation).to receive(:to)
    allow(driver).to receive(:execute_script)

    allow(client).to receive(:with_recoverable_session).and_yield
    allow(client).to receive(:with_authenticated_driver).and_yield(driver)
    allow(client).to receive(:with_task_capture).and_yield
    allow(client).to receive(:wait_for)
    allow(client).to receive(:dismiss_common_overlays!)
    allow(client).to receive(:sleep)
  end

  it "persists eligible feed posts to workspace profile posts and enqueues processing" do
    account = InstagramAccount.create!(username: "acct_#{SecureRandom.hex(4)}")
    profile = account.instagram_profiles.create!(
      username: "friend_#{SecureRandom.hex(3)}",
      following: true,
      follows_you: true
    )

    client = described_class.new(account: account)
    driver = instance_double("SeleniumDriver")
    stub_feed_capture_environment(client: client, driver: driver)

    taken_at = 30.minutes.ago.change(usec: 0)
    shortcode = "feed_#{SecureRandom.hex(3)}"
    allow(client).to receive(:extract_feed_items_from_dom).and_return(
      [
        {
          shortcode: shortcode,
          post_kind: "post",
          author_username: profile.username,
          author_ig_user_id: nil,
          media_url: "https://cdn.example.com/media.jpg",
          caption: "Weekend hike",
          taken_at: taken_at,
          metadata: { "source" => "api_timeline", "media_type" => 1, "like_count" => 12, "comment_count" => 2 }
        }
      ]
    )

    policy = instance_double(Instagram::ProfileScanPolicy, decision: { skip_post_analysis: false, reason_code: "scan_allowed" })
    allow(Instagram::ProfileScanPolicy).to receive(:new).with(profile: profile).and_return(policy)
    allow(DownloadInstagramPostMediaJob).to receive(:perform_later).and_return(double(job_id: "job-cache-dl"))
    allow(AnalyzeInstagramPostJob).to receive(:perform_later).and_return(double(job_id: "job-cache-ai"))
    allow(DownloadInstagramProfilePostMediaJob).to receive(:perform_later).and_return(double(job_id: "job-profile-dl"))
    allow(WorkspaceProcessActionsTodoPostJob).to receive(:enqueue_if_needed!).and_return({ enqueued: true, reason: "queued" })
    allow(Ops::StructuredLogger).to receive(:info)
    allow(Ops::StructuredLogger).to receive(:warn)

    result = client.capture_home_feed_posts!(rounds: 1, delay_seconds: 10, max_new: 10)

    expect(result[:seen_posts]).to eq(1)
    expect(result[:new_posts]).to eq(1)
    expect(result[:queued_actions]).to eq(1)
    expect(result[:skipped_posts]).to eq(0)

    post = profile.instagram_profile_posts.find_by(shortcode: shortcode)
    expect(post).to be_present
    expect(post.instagram_account_id).to eq(account.id)
    expect(post.taken_at.to_i).to eq(taken_at.to_i)
    expect(post.metadata["source"]).to eq("feed_capture_home")
    expect(post.metadata.dig("feed_capture_home", "author_username")).to eq(profile.username)

    expect(WorkspaceProcessActionsTodoPostJob).to have_received(:enqueue_if_needed!).with(
      account: account,
      profile: profile,
      post: post,
      requested_by: "feed_capture_home"
    )
  end

  it "skips non-followed and policy-blocked profiles and returns reason counters" do
    account = InstagramAccount.create!(username: "acct_#{SecureRandom.hex(4)}")
    unfollowed = account.instagram_profiles.create!(username: "random_#{SecureRandom.hex(3)}", following: false, follows_you: false)
    page_like = account.instagram_profiles.create!(username: "brand_#{SecureRandom.hex(3)}", following: true, follows_you: false)

    client = described_class.new(account: account)
    driver = instance_double("SeleniumDriver")
    stub_feed_capture_environment(client: client, driver: driver)

    allow(client).to receive(:extract_feed_items_from_dom).and_return(
      [
        {
          shortcode: "skip_unfollowed_#{SecureRandom.hex(2)}",
          post_kind: "post",
          author_username: unfollowed.username,
          media_url: "https://cdn.example.com/u.jpg",
          caption: "hello",
          metadata: {}
        },
        {
          shortcode: "skip_policy_#{SecureRandom.hex(2)}",
          post_kind: "post",
          author_username: page_like.username,
          media_url: "https://cdn.example.com/p.jpg",
          caption: "promo",
          metadata: {}
        }
      ]
    )

    allow(Instagram::ProfileScanPolicy).to receive(:new).with(profile: page_like).and_return(
      instance_double(
        Instagram::ProfileScanPolicy,
        decision: { skip_post_analysis: true, reason_code: "non_personal_profile_page" }
      )
    )
    allow(DownloadInstagramPostMediaJob).to receive(:perform_later).and_return(double(job_id: "job-cache-dl"))
    allow(AnalyzeInstagramPostJob).to receive(:perform_later).and_return(double(job_id: "job-cache-ai"))
    allow(WorkspaceProcessActionsTodoPostJob).to receive(:enqueue_if_needed!)
    allow(Ops::StructuredLogger).to receive(:info)
    allow(Ops::StructuredLogger).to receive(:warn)

    result = client.capture_home_feed_posts!(rounds: 1, delay_seconds: 10, max_new: 10)

    expect(result[:new_posts]).to eq(0)
    expect(result[:queued_actions]).to eq(0)
    expect(result[:skipped_posts]).to eq(2)
    expect(result[:skipped_reasons]["profile_not_in_follow_graph"]).to eq(1)
    expect(result[:skipped_reasons]["profile_policy_non_personal_profile_page"]).to eq(1)
    expect(page_like.instagram_profile_posts.count).to eq(0)
    expect(unfollowed.instagram_profile_posts.count).to eq(0)
    expect(DownloadInstagramPostMediaJob).not_to have_received(:perform_later)
    expect(AnalyzeInstagramPostJob).not_to have_received(:perform_later)
    expect(WorkspaceProcessActionsTodoPostJob).not_to have_received(:enqueue_if_needed!)
  end

  it "skips suggested feed items as irrelevant content" do
    account = InstagramAccount.create!(username: "acct_#{SecureRandom.hex(4)}")
    profile = account.instagram_profiles.create!(
      username: "friend_#{SecureRandom.hex(3)}",
      following: true,
      follows_you: true
    )

    client = described_class.new(account: account)
    driver = instance_double("SeleniumDriver")
    stub_feed_capture_environment(client: client, driver: driver)

    allow(client).to receive(:extract_feed_items_from_dom).and_return(
      [
        {
          shortcode: "skip_suggested_#{SecureRandom.hex(2)}",
          post_kind: "post",
          author_username: profile.username,
          media_url: "https://cdn.example.com/suggested.jpg",
          caption: "suggested",
          metadata: { "source" => "api_timeline", "is_suggested" => true }
        }
      ]
    )

    allow(Instagram::ProfileScanPolicy).to receive(:new).with(profile: profile).and_return(
      instance_double(
        Instagram::ProfileScanPolicy,
        decision: { skip_post_analysis: false, reason_code: "scan_allowed" }
      )
    )
    allow(DownloadInstagramPostMediaJob).to receive(:perform_later).and_return(double(job_id: "job-cache-dl"))
    allow(AnalyzeInstagramPostJob).to receive(:perform_later).and_return(double(job_id: "job-cache-ai"))
    allow(WorkspaceProcessActionsTodoPostJob).to receive(:enqueue_if_needed!)
    allow(Ops::StructuredLogger).to receive(:info)
    allow(Ops::StructuredLogger).to receive(:warn)

    result = client.capture_home_feed_posts!(rounds: 1, delay_seconds: 10, max_new: 10)

    expect(result[:new_posts]).to eq(0)
    expect(result[:queued_actions]).to eq(0)
    expect(result[:skipped_posts]).to eq(1)
    expect(result[:skipped_reasons]["suggested_or_irrelevant"]).to eq(1)
    expect(profile.instagram_profile_posts.count).to eq(0)
    expect(DownloadInstagramPostMediaJob).not_to have_received(:perform_later)
    expect(AnalyzeInstagramPostJob).not_to have_received(:perform_later)
    expect(WorkspaceProcessActionsTodoPostJob).not_to have_received(:enqueue_if_needed!)
  end

  it "allows feed capture when follow graph relationship data is unavailable for the account" do
    account = InstagramAccount.create!(username: "acct_#{SecureRandom.hex(4)}")
    26.times do |index|
      account.instagram_profiles.create!(username: "known_#{index}_#{SecureRandom.hex(2)}", following: false, follows_you: false)
    end
    profile = account.instagram_profiles.create!(
      username: "fallback_friend_#{SecureRandom.hex(3)}",
      following: false,
      follows_you: false
    )

    client = described_class.new(account: account)
    driver = instance_double("SeleniumDriver")
    stub_feed_capture_environment(client: client, driver: driver)

    shortcode = "fallback_#{SecureRandom.hex(3)}"
    allow(client).to receive(:extract_feed_items_from_dom).and_return(
      [
        {
          shortcode: shortcode,
          post_kind: "post",
          author_username: profile.username,
          media_url: "https://cdn.example.com/fallback.jpg",
          caption: "Fallback relationship",
          metadata: { "source" => "api_timeline" }
        }
      ]
    )

    allow(Instagram::ProfileScanPolicy).to receive(:new).with(profile: profile).and_return(
      instance_double(
        Instagram::ProfileScanPolicy,
        decision: { skip_post_analysis: false, reason_code: "scan_allowed" }
      )
    )
    allow(DownloadInstagramPostMediaJob).to receive(:perform_later).and_return(double(job_id: "job-cache-dl"))
    allow(AnalyzeInstagramPostJob).to receive(:perform_later).and_return(double(job_id: "job-cache-ai"))
    allow(DownloadInstagramProfilePostMediaJob).to receive(:perform_later).and_return(double(job_id: "job-profile-dl"))
    allow(WorkspaceProcessActionsTodoPostJob).to receive(:enqueue_if_needed!).and_return({ enqueued: true, reason: "queued" })
    allow(Ops::StructuredLogger).to receive(:info)
    allow(Ops::StructuredLogger).to receive(:warn)

    result = client.capture_home_feed_posts!(rounds: 1, delay_seconds: 10, max_new: 10)

    expect(result[:new_posts]).to eq(1)
    expect(result[:queued_actions]).to eq(1)
    expect(result[:skipped_posts]).to eq(0)
    expect(result[:skipped_reasons]).to eq({})

    post = profile.instagram_profile_posts.find_by(shortcode: shortcode)
    expect(post).to be_present
    expect(WorkspaceProcessActionsTodoPostJob).to have_received(:enqueue_if_needed!).with(
      account: account,
      profile: profile,
      post: post,
      requested_by: "feed_capture_home"
    )
  end
end
