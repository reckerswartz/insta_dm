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

  it "queues build history fallback for inline comment generation when profile context is incomplete" do
    account = InstagramAccount.create!(username: "acct_#{SecureRandom.hex(4)}")
    profile = account.instagram_profiles.create!(
      username: "profile_#{SecureRandom.hex(4)}",
      followers_count: 1200
    )
    post = profile.instagram_profile_posts.create!(
      instagram_account: account,
      shortcode: "post_#{SecureRandom.hex(3)}",
      ai_status: "analyzed",
      analyzed_at: Time.current,
      analysis: {},
      metadata: { "post_kind" => "post" }
    )

    allow_any_instance_of(Ai::PostCommentGenerationService).to receive(:run!) do
      post.reload
      metadata = post.metadata.is_a?(Hash) ? post.metadata.deep_dup : {}
      analysis = post.analysis.is_a?(Hash) ? post.analysis.deep_dup : {}
      analysis["comment_suggestions"] = []
      analysis["comment_generation_status"] = "blocked_missing_required_evidence"
      metadata["comment_generation_policy"] = {
        "status" => "blocked",
        "history_ready" => false,
        "history_reason_code" => "latest_posts_not_analyzed",
        "blocked_reason_code" => "missing_required_evidence"
      }
      post.update!(metadata: metadata, analysis: analysis)
      {
        blocked: true,
        status: "blocked_missing_required_evidence",
        source: "policy",
        suggestions_count: 0,
        reason_code: "missing_required_evidence"
      }
    end

    expect(BuildInstagramProfileHistoryJob).to receive(:enqueue_with_resume_if_needed!).and_return(
      {
        accepted: true,
        queued: true,
        registered: true,
        reason: "build_history_queued",
        action_log_id: 123,
        job_id: "history_job_1",
        next_run_at: nil
      }
    )

    AnalyzeInstagramProfilePostJob.perform_now(
      instagram_account_id: account.id,
      instagram_profile_id: profile.id,
      instagram_profile_post_id: post.id,
      pipeline_mode: "inline",
      task_flags: {
        analyze_visual: false,
        analyze_faces: false,
        run_ocr: false,
        run_video: false,
        run_metadata: false,
        generate_comments: true,
        enforce_comment_evidence_policy: true,
        retry_on_incomplete_profile: true
      }
    )

    post.reload
    retry_state = post.metadata.dig("comment_generation_policy", "retry_state")
    assert_equal "build_history_fallback", retry_state["mode"]
    assert_equal 123, retry_state["build_history_action_log_id"]
  end

  it "continues comment generation and queues build history in background when history is pending" do
    account = InstagramAccount.create!(username: "acct_#{SecureRandom.hex(4)}")
    profile = account.instagram_profiles.create!(
      username: "profile_#{SecureRandom.hex(4)}",
      followers_count: 1200
    )
    post = profile.instagram_profile_posts.create!(
      instagram_account: account,
      shortcode: "post_#{SecureRandom.hex(3)}",
      ai_status: "analyzed",
      analyzed_at: Time.current,
      analysis: {},
      metadata: { "post_kind" => "post" }
    )

    allow_any_instance_of(Ai::PostCommentGenerationService).to receive(:run!) do
      post.reload
      metadata = post.metadata.is_a?(Hash) ? post.metadata.deep_dup : {}
      analysis = post.analysis.is_a?(Hash) ? post.analysis.deep_dup : {}
      analysis["comment_suggestions"] = [ "Looks great." ]
      analysis["comment_generation_status"] = "ok"
      metadata["comment_generation_policy"] = {
        "status" => "enabled_history_pending",
        "history_ready" => false,
        "history_reason_code" => "latest_posts_not_analyzed"
      }
      post.update!(metadata: metadata, analysis: analysis)
      {
        blocked: false,
        status: "ok",
        source: "ollama",
        suggestions_count: 1,
        reason_code: nil
      }
    end

    expect(BuildInstagramProfileHistoryJob).to receive(:enqueue_with_resume_if_needed!).and_return(
      {
        accepted: true,
        queued: true,
        registered: true,
        reason: "build_history_queued",
        action_log_id: 456,
        job_id: "history_job_2",
        next_run_at: nil
      }
    )

    AnalyzeInstagramProfilePostJob.perform_now(
      instagram_account_id: account.id,
      instagram_profile_id: profile.id,
      instagram_profile_post_id: post.id,
      pipeline_mode: "inline",
      task_flags: {
        analyze_visual: false,
        analyze_faces: false,
        run_ocr: false,
        run_video: false,
        run_metadata: false,
        generate_comments: true,
        enforce_comment_evidence_policy: true,
        retry_on_incomplete_profile: true
      }
    )

    post.reload
    retry_state = post.metadata.dig("comment_generation_policy", "retry_state")
    assert_equal "build_history_fallback", retry_state["mode"]
    assert_equal 456, retry_state["build_history_action_log_id"]
    assert_equal [ "Looks great." ], Array(post.analysis["comment_suggestions"])
  end
end
