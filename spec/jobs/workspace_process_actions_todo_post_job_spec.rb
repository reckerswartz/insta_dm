require "rails_helper"
require "securerandom"
require "stringio"

RSpec.describe "WorkspaceProcessActionsTodoPostJobTest" do
  include ActiveJob::TestHelper

  before do
    clear_enqueued_jobs
    clear_performed_jobs
  end

  it "queues comment generation as a separate background job when post analysis is ready" do
    account = InstagramAccount.create!(username: "acct_#{SecureRandom.hex(4)}")
    profile = account.instagram_profiles.create!(username: "profile_#{SecureRandom.hex(4)}")
    post = profile.instagram_profile_posts.create!(
      instagram_account: account,
      shortcode: "post_#{SecureRandom.hex(3)}",
      taken_at: Time.current,
      ai_status: "analyzed",
      analyzed_at: Time.current,
      analysis: { "image_description" => "Street portrait" },
      metadata: { "post_kind" => "post" }
    )
    post.media.attach(
      io: StringIO.new("fake-jpeg"),
      filename: "post.jpg",
      content_type: "image/jpeg"
    )

    WorkspaceProcessActionsTodoPostJob.perform_now(
      instagram_account_id: account.id,
      instagram_profile_id: profile.id,
      instagram_profile_post_id: post.id,
      requested_by: "rspec"
    )

    post.reload
    workspace_state = post.metadata.dig("workspace_actions")

    assert_equal "waiting_comment_generation", workspace_state["status"]
    assert workspace_state["comment_generation_job_id"].to_s.present?
    assert_equal 1, workspace_state["comment_generation_retry_attempts"].to_i

    enqueued = enqueued_jobs.map { |row| row[:job] }
    assert_includes enqueued, GeneratePostCommentSuggestionsJob
  end

  it "marks waiting_build_history when comment policy indicates incomplete history and retry is already registered" do
    account = InstagramAccount.create!(username: "acct_#{SecureRandom.hex(4)}")
    profile = account.instagram_profiles.create!(username: "profile_#{SecureRandom.hex(4)}")
    post = profile.instagram_profile_posts.create!(
      instagram_account: account,
      shortcode: "post_#{SecureRandom.hex(3)}",
      taken_at: Time.current,
      ai_status: "analyzed",
      analyzed_at: Time.current,
      analysis: { "image_description" => "Street portrait" },
      metadata: {
        "post_kind" => "post",
        "comment_generation_policy" => {
          "status" => "blocked",
          "history_ready" => false,
          "history_reason_code" => "latest_posts_not_analyzed",
          "retry_state" => {
            "next_run_at" => 10.minutes.from_now.iso8601(3),
            "last_reason_code" => "latest_posts_not_analyzed"
          }
        }
      }
    )
    post.media.attach(
      io: StringIO.new("fake-jpeg"),
      filename: "post.jpg",
      content_type: "image/jpeg"
    )

    WorkspaceProcessActionsTodoPostJob.perform_now(
      instagram_account_id: account.id,
      instagram_profile_id: profile.id,
      instagram_profile_post_id: post.id,
      requested_by: "rspec"
    )

    post.reload
    workspace_state = post.metadata.dig("workspace_actions")

    assert_equal "waiting_build_history", workspace_state["status"]
    assert_equal "latest_posts_not_analyzed", workspace_state["last_error"].to_s

    enqueued = enqueued_jobs.map { |row| row[:job] }
    refute_includes enqueued, GeneratePostCommentSuggestionsJob
    refute_includes enqueued, BuildInstagramProfileHistoryJob
  end

it "enqueues when post is not ready" do
  account = InstagramAccount.create!(username: "acct_#{SecureRandom.hex(4)}")
  profile = account.instagram_profiles.create!(username: "profile_#{SecureRandom.hex(4)}")
  post = profile.instagram_profile_posts.create!(
    instagram_account: account,
    shortcode: "post_#{SecureRandom.hex(3)}",
    taken_at: Time.current,
    ai_status: "pending",
    metadata: { "post_kind" => "post" }
  )

  result = WorkspaceProcessActionsTodoPostJob.enqueue_if_needed!(
    account: account,
    profile: profile,
    post: post,
    requested_by: "rspec"
  )

  expect(result[:enqueued]).to eq(true)
  post.reload
  expect(post.metadata.dig("workspace_actions", "status")).to eq("queued")
end

it "returns already_ready when suggestions exist" do
  account = InstagramAccount.create!(username: "acct_#{SecureRandom.hex(4)}")
  profile = account.instagram_profiles.create!(username: "profile_#{SecureRandom.hex(4)}")
  post = profile.instagram_profile_posts.create!(
    instagram_account: account,
    shortcode: "post_#{SecureRandom.hex(3)}",
    taken_at: Time.current,
    ai_status: "analyzed",
    analyzed_at: Time.current,
    analysis: { "comment_suggestions" => [ "Nice shot" ] },
    metadata: { "post_kind" => "post" }
  )

  result = WorkspaceProcessActionsTodoPostJob.enqueue_if_needed!(
    account: account,
    profile: profile,
    post: post,
    requested_by: "rspec"
  )

  expect(result).to include(enqueued: false, reason: "already_ready")
end

it "marks story posts as skipped_non_user_post" do
  account = InstagramAccount.create!(username: "acct_#{SecureRandom.hex(4)}")
  profile = account.instagram_profiles.create!(username: "profile_#{SecureRandom.hex(4)}")
  post = profile.instagram_profile_posts.create!(
    instagram_account: account,
    shortcode: "post_#{SecureRandom.hex(3)}",
    taken_at: Time.current,
    ai_status: "pending",
    metadata: { "post_kind" => "story" }
  )

  WorkspaceProcessActionsTodoPostJob.perform_now(
    instagram_account_id: account.id,
    instagram_profile_id: profile.id,
    instagram_profile_post_id: post.id,
    requested_by: "rspec"
  )

  post.reload
  expect(post.metadata.dig("workspace_actions", "status")).to eq("skipped_non_user_post")
end

it "stops retrying waiting_post_analysis after max attempts" do
  stub_const("WorkspaceProcessActionsTodoPostJob::POST_ANALYSIS_RETRY_MAX_ATTEMPTS", 1)

  account = InstagramAccount.create!(username: "acct_#{SecureRandom.hex(4)}")
  profile = account.instagram_profiles.create!(username: "profile_#{SecureRandom.hex(4)}")
  post = profile.instagram_profile_posts.create!(
    instagram_account: account,
    shortcode: "post_#{SecureRandom.hex(3)}",
    taken_at: Time.current,
    ai_status: "running",
    metadata: { "post_kind" => "post" }
  )
  post.media.attach(
    io: StringIO.new("fake-jpeg"),
    filename: "post.jpg",
    content_type: "image/jpeg"
  )

  WorkspaceProcessActionsTodoPostJob.perform_now(
    instagram_account_id: account.id,
    instagram_profile_id: profile.id,
    instagram_profile_post_id: post.id,
    requested_by: "rspec"
  )

  post.reload
  expect(post.metadata.dig("workspace_actions", "status")).to eq("waiting_post_analysis")
  expect(post.metadata.dig("workspace_actions", "post_analysis_retry_attempts")).to eq(1)

  WorkspaceProcessActionsTodoPostJob.perform_now(
    instagram_account_id: account.id,
    instagram_profile_id: profile.id,
    instagram_profile_post_id: post.id,
    requested_by: "rspec"
  )

  post.reload
  expect(post.metadata.dig("workspace_actions", "status")).to eq("failed")
  expect(post.metadata.dig("workspace_actions", "last_error")).to include("waiting_post_analysis_retry_attempts_exhausted")
end
end
