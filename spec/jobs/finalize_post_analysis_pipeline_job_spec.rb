require "rails_helper"
require "securerandom"

RSpec.describe "FinalizePostAnalysisPipelineJobTest" do
  include ActiveJob::TestHelper

  before do
    clear_enqueued_jobs
    clear_performed_jobs
  end

  it "marks post analyzed when required pipeline steps are completed" do
    account, profile, post, run_id = build_pipeline_with_visual_status(status: "succeeded")

    FinalizePostAnalysisPipelineJob.perform_now(
      instagram_account_id: account.id,
      instagram_profile_id: profile.id,
      instagram_profile_post_id: post.id,
      pipeline_run_id: run_id,
      attempts: 0
    )

    post.reload
    assert_equal "analyzed", post.ai_status
    assert post.analyzed_at.present?
    assert_equal "completed", post.metadata.dig("ai_pipeline", "status")
    assert_equal "succeeded", post.metadata.dig("ai_pipeline", "steps", "visual", "status")
  end

  it "merges enriched video context into final analysis payload" do
    account, profile, post, run_id = build_pipeline_with_visual_status(status: "succeeded")
    post.update!(
      analysis: {
        "topics" => [ "city" ],
        "image_description" => "Street photo at sunset."
      },
      metadata: post.metadata.deep_dup.merge(
        "video_processing" => {
          "processing_mode" => "static_image",
          "static" => true,
          "semantic_route" => "image",
          "duration_seconds" => 5.8,
          "transcript" => "City lights and music.",
          "topics" => [ "music", "street" ],
          "objects" => [ "person" ],
          "hashtags" => [ "#city" ],
          "mentions" => [ "@friend" ],
          "profile_handles" => [ "friend.profile" ],
          "ocr_text" => "CITY NIGHTS",
          "ocr_blocks" => [ { "text" => "CITY NIGHTS" } ],
          "context_summary" => "Static visual video detected and routed through image-style analysis."
        }
      )
    )

    FinalizePostAnalysisPipelineJob.perform_now(
      instagram_account_id: account.id,
      instagram_profile_id: profile.id,
      instagram_profile_post_id: post.id,
      pipeline_run_id: run_id,
      attempts: 0
    )

    post.reload
    assert_equal "static_image", post.analysis["video_processing_mode"]
    assert_equal true, ActiveModel::Type::Boolean.new.cast(post.analysis["video_static_detected"])
    assert_equal "image", post.analysis["video_semantic_route"]
    assert_equal "City lights and music.", post.analysis["transcript"]
    assert_equal "CITY NIGHTS", post.analysis["ocr_text"]
    assert_includes Array(post.analysis["topics"]), "city"
    assert_includes Array(post.analysis["topics"]), "music"
    assert_includes Array(post.analysis["hashtags"]), "#city"
  end

  it "skips duplicate finalizer runs while another finalize lock is active" do
    account, profile, post, run_id = build_pipeline_with_visual_status(status: "running")
    metadata = post.metadata.deep_dup
    metadata["ai_pipeline"]["finalizer"] = {
      "lock_until" => (Time.current + 30.seconds).iso8601(3)
    }
    post.update!(metadata: metadata)

    assert_no_enqueued_jobs only: FinalizePostAnalysisPipelineJob do
      FinalizePostAnalysisPipelineJob.perform_now(
        instagram_account_id: account.id,
        instagram_profile_id: profile.id,
        instagram_profile_post_id: post.id,
        pipeline_run_id: run_id,
        attempts: 4
      )
    end
  end

  it "reschedules with bounded backoff when required steps are still running" do
    account, profile, post, run_id = build_pipeline_with_visual_status(status: "running")
    started_at = Time.current

    FinalizePostAnalysisPipelineJob.perform_now(
      instagram_account_id: account.id,
      instagram_profile_id: profile.id,
      instagram_profile_post_id: post.id,
      pipeline_run_id: run_id,
      attempts: 9
    )

    enqueued = enqueued_jobs.select { |row| row[:job] == FinalizePostAnalysisPipelineJob }
    assert_operator enqueued.length, :>=, 1
    scheduled_job = enqueued.last
    assert scheduled_job[:at].present?

    delay_seconds = scheduled_job[:at].to_f - started_at.to_f
    assert_operator delay_seconds, :>=, 14
    assert_operator delay_seconds, :<=, 18
  end

  it "reinitializes stalled queued steps so pipeline can recover missing extraction outputs" do
    account, profile, post, run_id = build_pipeline_with_visual_status(status: "succeeded")

    metadata = post.metadata.deep_dup
    metadata["ai_pipeline"]["required_steps"] = ["visual", "ocr", "metadata"]
    metadata["ai_pipeline"]["steps"]["ocr"] = {
      "status" => "queued",
      "attempts" => 0,
      "queue_name" => "ai_ocr_queue",
      "active_job_id" => "stalled-ocr-job",
      "created_at" => 10.minutes.ago.iso8601(3),
      "result" => {
        "enqueued_at" => 10.minutes.ago.iso8601(3)
      }
    }
    metadata["ai_pipeline"]["steps"]["metadata"] = {
      "status" => "pending",
      "attempts" => 0,
      "result" => {},
      "created_at" => Time.current.iso8601(3)
    }
    post.update!(metadata: metadata, ai_status: "running")

    FinalizePostAnalysisPipelineJob.perform_now(
      instagram_account_id: account.id,
      instagram_profile_id: profile.id,
      instagram_profile_post_id: post.id,
      pipeline_run_id: run_id,
      attempts: 6
    )

    post.reload
    assert_equal "queued", post.metadata.dig("ai_pipeline", "steps", "ocr", "status")
    assert_equal "step_reinitialized", post.metadata.dig("ai_pipeline", "steps", "ocr", "result", "reason")
    assert_equal 1, post.metadata.dig("ai_pipeline", "steps", "ocr", "result", "reinitialize_attempts").to_i
    assert_enqueued_jobs 1, only: FinalizePostAnalysisPipelineJob
    assert_enqueued_jobs 1, only: ProcessPostOcrAnalysisJob
  end

  it "ignores stale finalizer jobs after pipeline is already terminal" do
    account, profile, post, run_id = build_pipeline_with_visual_status(status: "failed", pipeline_status: "failed")
    before_metadata = post.metadata.deep_dup

    assert_no_enqueued_jobs only: FinalizePostAnalysisPipelineJob do
      FinalizePostAnalysisPipelineJob.perform_now(
        instagram_account_id: account.id,
        instagram_profile_id: profile.id,
        instagram_profile_post_id: post.id,
        pipeline_run_id: run_id,
        attempts: 12
      )
    end

    post.reload
    assert_equal before_metadata["ai_pipeline"]["status"], post.metadata.dig("ai_pipeline", "status")
    assert_equal before_metadata["ai_pipeline"]["steps"]["visual"]["status"], post.metadata.dig("ai_pipeline", "steps", "visual", "status")
  end

  it "reinitializes only failed core extraction steps before metadata tagging" do
    account, profile, post, run_id = build_pipeline_with_visual_status(status: "succeeded")
    metadata = post.metadata.deep_dup
    metadata["ai_pipeline"]["required_steps"] = ["visual", "ocr", "metadata"]
    metadata["ai_pipeline"]["steps"]["ocr"] = {
      "status" => "failed",
      "attempts" => 1,
      "queue_name" => "ai_ocr_queue",
      "active_job_id" => "failed-ocr-job",
      "result" => { "reason" => "ocr_analysis_failed" },
      "error" => "Timeout::Error",
      "created_at" => 2.minutes.ago.iso8601(3),
      "finished_at" => 2.minutes.ago.iso8601(3)
    }
    metadata["ai_pipeline"]["steps"]["metadata"] = {
      "status" => "pending",
      "attempts" => 0,
      "result" => {},
      "created_at" => Time.current.iso8601(3)
    }
    post.update!(metadata: metadata, ai_status: "running")

    FinalizePostAnalysisPipelineJob.perform_now(
      instagram_account_id: account.id,
      instagram_profile_id: profile.id,
      instagram_profile_post_id: post.id,
      pipeline_run_id: run_id,
      attempts: 2
    )

    enqueued = enqueued_jobs.map { |row| row[:job] }
    assert_includes enqueued, ProcessPostOcrAnalysisJob
    refute_includes enqueued, ProcessPostMetadataTaggingJob

    post.reload
    ocr_step = post.metadata.dig("ai_pipeline", "steps", "ocr")
    assert_equal "queued", ocr_step["status"]
    assert_equal 1, ocr_step.dig("result", "reinitialize_attempts").to_i
    assert_equal "step_reinitialized", ocr_step.dig("result", "reason")
  end

  it "falls back failed video step to keep metadata flow responsive" do
    account, profile, post, run_id = build_pipeline_with_visual_status(status: "succeeded")
    metadata = post.metadata.deep_dup
    metadata["ai_pipeline"]["required_steps"] = ["visual", "video", "metadata"]
    metadata["ai_pipeline"]["steps"]["video"] = {
      "status" => "failed",
      "attempts" => 1,
      "queue_name" => "video_processing_queue",
      "active_job_id" => "failed-video-job",
      "result" => { "reason" => "video_analysis_failed" },
      "error" => "Timeout::Error: execution expired",
      "created_at" => 3.minutes.ago.iso8601(3),
      "finished_at" => 2.minutes.ago.iso8601(3)
    }
    metadata["ai_pipeline"]["steps"]["metadata"] = {
      "status" => "pending",
      "attempts" => 0,
      "result" => {},
      "created_at" => Time.current.iso8601(3)
    }
    post.update!(metadata: metadata, ai_status: "running")

    assert_no_enqueued_jobs only: ProcessPostVideoAnalysisJob do
      assert_enqueued_jobs 1, only: ProcessPostMetadataTaggingJob do
        FinalizePostAnalysisPipelineJob.perform_now(
          instagram_account_id: account.id,
          instagram_profile_id: profile.id,
          instagram_profile_post_id: post.id,
          pipeline_run_id: run_id,
          attempts: 0
        )
      end
    end

    post.reload
    assert_equal "succeeded", post.metadata.dig("ai_pipeline", "steps", "video", "status")
    assert_equal "video_step_failed_fallback_to_visual_metadata", post.metadata.dig("ai_pipeline", "steps", "video", "result", "reason")
    assert_equal true, ActiveModel::Type::Boolean.new.cast(post.metadata.dig("video_processing", "fallback", "applied"))
  end

  it "fails metadata dependency step when core extraction outputs cannot be recovered" do
    account, profile, post, run_id = build_pipeline_with_visual_status(status: "succeeded")
    metadata = post.metadata.deep_dup
    metadata["ai_pipeline"]["required_steps"] = ["visual", "ocr", "metadata"]
    metadata["ai_pipeline"]["steps"]["ocr"] = {
      "status" => "failed",
      "attempts" => 3,
      "queue_name" => "ai_ocr_queue",
      "active_job_id" => "failed-ocr-job",
      "result" => {
        "reason" => "ocr_analysis_failed",
        "reinitialize_attempts" => 2
      },
      "error" => "Timeout::Error",
      "created_at" => 6.minutes.ago.iso8601(3),
      "finished_at" => 5.minutes.ago.iso8601(3)
    }
    metadata["ai_pipeline"]["steps"]["metadata"] = {
      "status" => "pending",
      "attempts" => 0,
      "result" => {},
      "created_at" => Time.current.iso8601(3)
    }
    post.update!(metadata: metadata, ai_status: "running")

    assert_no_enqueued_jobs only: ProcessPostMetadataTaggingJob do
      FinalizePostAnalysisPipelineJob.perform_now(
        instagram_account_id: account.id,
        instagram_profile_id: profile.id,
        instagram_profile_post_id: post.id,
        pipeline_run_id: run_id,
        attempts: 25
      )
    end

    post.reload
    assert_equal "failed", post.ai_status
    assert_equal "failed", post.metadata.dig("ai_pipeline", "steps", "metadata", "status")
    assert_includes post.metadata.dig("ai_pipeline", "steps", "metadata", "error").to_s, "core_dependencies_failed"
  end

  it "enqueues secondary face analysis on the low-priority queue for ambiguous primary confidence" do
    account = InstagramAccount.create!(username: "acct_#{SecureRandom.hex(4)}")
    profile = account.instagram_profiles.create!(
      username: "profile_#{SecureRandom.hex(4)}",
      followers_count: 900
    )
    post = profile.instagram_profile_posts.create!(
      instagram_account: account,
      shortcode: "post_#{SecureRandom.hex(4)}",
      ai_status: "running",
      analysis: { "confidence" => 0.5, "image_description" => "Friends at a cafe." },
      metadata: {}
    )

    state = Ai::PostAnalysisPipelineState.new(post: post)
    run_id = state.start!(
      task_flags: {
        analyze_visual: true,
        analyze_faces: false,
        secondary_face_analysis: true,
        secondary_only_on_ambiguous: true,
        run_ocr: false,
        run_video: false,
        run_metadata: false
      },
      source_job: "spec"
    )
    state.mark_step_completed!(run_id: run_id, step: "visual", status: "succeeded", result: { provider: "local" })

    FinalizePostAnalysisPipelineJob.perform_now(
      instagram_account_id: account.id,
      instagram_profile_id: profile.id,
      instagram_profile_post_id: post.id,
      pipeline_run_id: run_id,
      attempts: 0
    )

    face_jobs = enqueued_jobs.select { |row| row[:job] == ProcessPostFaceAnalysisJob }
    assert_operator face_jobs.length, :>=, 1
    assert_equal "ai_face_secondary_queue", face_jobs.last[:queue]

    post.reload
    assert_equal "queued", post.metadata.dig("ai_pipeline", "steps", "face", "status")
    assert_equal "secondary_face_enqueued", post.metadata.dig("ai_pipeline", "steps", "face", "result", "reason")
  end

  it "skips secondary face analysis when primary confidence is high" do
    account = InstagramAccount.create!(username: "acct_#{SecureRandom.hex(4)}")
    profile = account.instagram_profiles.create!(
      username: "profile_#{SecureRandom.hex(4)}",
      followers_count: 900
    )
    post = profile.instagram_profile_posts.create!(
      instagram_account: account,
      shortcode: "post_#{SecureRandom.hex(4)}",
      ai_status: "running",
      analysis: { "confidence" => 0.92, "image_description" => "Owner selfie at home." },
      caption: "@friend #weekend",
      metadata: {}
    )

    state = Ai::PostAnalysisPipelineState.new(post: post)
    run_id = state.start!(
      task_flags: {
        analyze_visual: true,
        analyze_faces: false,
        secondary_face_analysis: true,
        secondary_only_on_ambiguous: true,
        run_ocr: false,
        run_video: false,
        run_metadata: false
      },
      source_job: "spec"
    )
    state.mark_step_completed!(run_id: run_id, step: "visual", status: "succeeded", result: { provider: "local" })

    assert_no_enqueued_jobs only: ProcessPostFaceAnalysisJob do
      FinalizePostAnalysisPipelineJob.perform_now(
        instagram_account_id: account.id,
        instagram_profile_id: profile.id,
        instagram_profile_post_id: post.id,
        pipeline_run_id: run_id,
        attempts: 0
      )
    end

    post.reload
    assert_equal "skipped", post.metadata.dig("ai_pipeline", "steps", "face", "status")
    assert_equal "secondary_face_not_needed", post.metadata.dig("ai_pipeline", "steps", "face", "result", "reason")
  end

  def build_pipeline_with_visual_status(status:, pipeline_status: "running")
    account = InstagramAccount.create!(username: "acct_#{SecureRandom.hex(4)}")
    profile = account.instagram_profiles.create!(
      username: "profile_#{SecureRandom.hex(4)}",
      followers_count: 900
    )
    post = profile.instagram_profile_posts.create!(
      instagram_account: account,
      shortcode: "post_#{SecureRandom.hex(4)}",
      ai_status: "pending",
      analysis: { "image_description" => "A bright landscape." },
      metadata: {}
    )

    run_id = SecureRandom.uuid
    post.update!(
      metadata: {
        "ai_pipeline" => {
          "run_id" => run_id,
          "status" => pipeline_status.to_s,
          "required_steps" => [ "visual" ],
          "steps" => {
            "visual" => {
              "status" => status.to_s,
              "attempts" => 1,
              "result" => { "provider" => "local" }
            },
            "face" => { "status" => "skipped", "attempts" => 0, "result" => {} },
            "ocr" => { "status" => "skipped", "attempts" => 0, "result" => {} },
            "video" => { "status" => "skipped", "attempts" => 0, "result" => {} },
            "metadata" => { "status" => "skipped", "attempts" => 0, "result" => {} }
          }
        }
      }
    )

    [ account, profile, post, run_id ]
  end
end
