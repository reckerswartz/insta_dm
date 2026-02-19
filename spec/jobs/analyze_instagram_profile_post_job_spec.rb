require "rails_helper"
require "securerandom"

RSpec.describe "AnalyzeInstagramProfilePostJobTest" do
  include ActiveJob::TestHelper

  before do
    clear_enqueued_jobs
    clear_performed_jobs
  end

  it "marks post as policy-skipped for high-follower profiles" do
    account = InstagramAccount.create!(username: "acct_#{SecureRandom.hex(4)}")
    profile = account.instagram_profiles.create!(
      username: "profile_#{SecureRandom.hex(4)}",
      followers_count: 30_000
    )
    post = profile.instagram_profile_posts.create!(
      instagram_account: account,
      shortcode: "post_#{SecureRandom.hex(3)}",
      ai_status: "pending",
      metadata: {
        "ai_pipeline_failure" => {
          "reason" => "pipeline_timeout",
          "failed_at" => 1.hour.ago.iso8601,
          "source" => "FinalizePostAnalysisPipelineJob"
        }
      }
    )

    AnalyzeInstagramProfilePostJob.perform_now(
      instagram_account_id: account.id,
      instagram_profile_id: profile.id,
      instagram_profile_post_id: post.id
    )

    post.reload
    assert_equal "analyzed", post.ai_status
    assert_not_nil post.analyzed_at
    assert_equal "policy", post.ai_provider
    assert_equal true, ActiveModel::Type::Boolean.new.cast(post.analysis["skipped"])
    assert_equal "followers_threshold_exceeded", post.analysis["reason_code"]
  end

  it "starts a modular post analysis pipeline and enqueues service-specific jobs" do
    account = InstagramAccount.create!(username: "acct_#{SecureRandom.hex(4)}")
    profile = account.instagram_profiles.create!(
      username: "profile_#{SecureRandom.hex(4)}",
      followers_count: 1200
    )
    post = profile.instagram_profile_posts.create!(
      instagram_account: account,
      shortcode: "post_#{SecureRandom.hex(3)}",
      ai_status: "pending"
    )

    AnalyzeInstagramProfilePostJob.perform_now(
      instagram_account_id: account.id,
      instagram_profile_id: profile.id,
      instagram_profile_post_id: post.id,
      pipeline_mode: "async",
      task_flags: {
        analyze_visual: true,
        analyze_faces: true,
        run_ocr: true,
        run_video: false,
        run_metadata: true
      }
    )

    enqueued = enqueued_jobs.map { |row| row[:job] }
    assert_includes enqueued, ProcessPostVisualAnalysisJob
    assert_includes enqueued, ProcessPostFaceAnalysisJob
    assert_includes enqueued, ProcessPostOcrAnalysisJob
    assert_includes enqueued, FinalizePostAnalysisPipelineJob
    refute_includes enqueued, ProcessPostVideoAnalysisJob

    pipeline = post.reload.metadata["ai_pipeline"]
    assert_equal "running", post.ai_status
    assert_nil post.metadata["ai_pipeline_failure"]
    assert_equal "running", pipeline["status"]
    assert_includes Array(pipeline["required_steps"]), "visual"
    assert_includes Array(pipeline["required_steps"]), "face"
    assert_includes Array(pipeline["required_steps"]), "ocr"
    refute_includes Array(pipeline["required_steps"]), "video"
  end
end
