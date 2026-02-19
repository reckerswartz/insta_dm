require "rails_helper"
require "securerandom"
require "stringio"

RSpec.describe "WorkspaceProcessActionsTodoPostJobTest" do
  include ActiveJob::TestHelper

  before do
    clear_enqueued_jobs
    clear_performed_jobs
  end

  it "queues profile analysis and retry when profile context is incomplete" do
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

    assert_equal "waiting_profile_analysis", workspace_state["status"]
    assert workspace_state["next_run_at"].present?
    assert_equal "latest_posts_not_analyzed", workspace_state["profile_retry_reason_code"]

    enqueued = enqueued_jobs.map { |row| row[:job] }
    assert_includes enqueued, AnalyzeInstagramProfileJob
    assert_includes enqueued, WorkspaceProcessActionsTodoPostJob
  end
end
