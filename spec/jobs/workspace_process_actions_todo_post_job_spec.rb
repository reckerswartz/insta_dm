require "rails_helper"
require "securerandom"
require "stringio"

RSpec.describe "WorkspaceProcessActionsTodoPostJobTest" do
  include ActiveJob::TestHelper

  before do
    clear_enqueued_jobs
    clear_performed_jobs
  end

  it "queues build history fallback when profile context is incomplete" do
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

    allow_any_instance_of(Ai::PostCommentGenerationService).to receive(:run!) do
      post.reload
      analysis = post.analysis.is_a?(Hash) ? post.analysis.deep_dup : {}
      metadata = post.metadata.is_a?(Hash) ? post.metadata.deep_dup : {}
      analysis["comment_suggestions"] = []
      analysis["comment_generation_status"] = "blocked_missing_required_evidence"
      metadata["comment_generation_policy"] = {
        "status" => "blocked",
        "history_ready" => false,
        "history_reason_code" => "latest_posts_not_analyzed",
        "blocked_reason_code" => "missing_required_evidence",
        "blocked_reason" => "Latest posts have not been fully analyzed yet."
      }
      post.update!(analysis: analysis, metadata: metadata)

      {
        blocked: true,
        status: "blocked_missing_required_evidence",
        source: "policy",
        suggestions_count: 0,
        reason_code: "missing_required_evidence"
      }
    end

    WorkspaceProcessActionsTodoPostJob.perform_now(
      instagram_account_id: account.id,
      instagram_profile_id: profile.id,
      instagram_profile_post_id: post.id,
      requested_by: "rspec"
    )

    post.reload
    workspace_state = post.metadata.dig("workspace_actions")

    assert_equal "waiting_build_history", workspace_state["status"]
    assert_equal "latest_posts_not_analyzed", workspace_state["profile_retry_reason_code"]
    assert workspace_state["build_history_action_log_id"].to_i.positive?

    enqueued = enqueued_jobs.map { |row| row[:job] }
    assert_includes enqueued, BuildInstagramProfileHistoryJob
  end

  it "keeps post ready and still queues build history when suggestions are generated with pending history" do
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

    allow_any_instance_of(Ai::PostCommentGenerationService).to receive(:run!) do
      post.reload
      analysis = post.analysis.is_a?(Hash) ? post.analysis.deep_dup : {}
      metadata = post.metadata.is_a?(Hash) ? post.metadata.deep_dup : {}
      analysis["comment_suggestions"] = [ "Nice frame." ]
      analysis["comment_generation_status"] = "ok"
      metadata["comment_generation_policy"] = {
        "status" => "enabled_history_pending",
        "history_ready" => false,
        "history_reason_code" => "latest_posts_not_analyzed"
      }
      post.update!(analysis: analysis, metadata: metadata)

      {
        blocked: false,
        status: "ok",
        source: "ollama",
        suggestions_count: 1,
        reason_code: nil
      }
    end

    WorkspaceProcessActionsTodoPostJob.perform_now(
      instagram_account_id: account.id,
      instagram_profile_id: profile.id,
      instagram_profile_post_id: post.id,
      requested_by: "rspec"
    )

    post.reload
    workspace_state = post.metadata.dig("workspace_actions")

    assert_equal "ready", workspace_state["status"]
    assert_equal 1, workspace_state["suggestions_count"]
    assert_equal "latest_posts_not_analyzed", workspace_state["profile_retry_reason_code"]
    assert workspace_state["build_history_action_log_id"].to_i.positive?

    enqueued = enqueued_jobs.map { |row| row[:job] }
    assert_includes enqueued, BuildInstagramProfileHistoryJob
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
    analysis: { "comment_suggestions" => ["Nice shot"] },
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
