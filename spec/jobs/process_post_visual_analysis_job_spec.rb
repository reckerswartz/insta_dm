require "rails_helper"
require "securerandom"

RSpec.describe "ProcessPostVisualAnalysisJobTest" do
  include ActiveJob::TestHelper

  before do
    clear_enqueued_jobs
    clear_performed_jobs
  end

  it "stores ai_analysis_id from object-like run records without crashing" do
    account, profile, post, run_id = build_pipeline_context

    provider = Struct.new(:key).new("local")
    analysis_record = Struct.new(:id).new(12_345)
    runner = instance_double(Ai::Runner)
    allow(Ai::Runner).to receive(:new).with(account: account).and_return(runner)
    allow(runner).to receive(:analyze!).and_return(
      {
        provider: provider,
        result: {
          model: "mistral:7b",
          analysis: { "image_description" => "A person near a beach." }
        },
        record: analysis_record,
        cached: false
      }
    )

    ProcessPostVisualAnalysisJob.perform_now(
      instagram_account_id: account.id,
      instagram_profile_id: profile.id,
      instagram_profile_post_id: post.id,
      pipeline_run_id: run_id
    )

    post.reload
    assert_equal "local", post.ai_provider
    assert_equal "mistral:7b", post.ai_model
    assert_equal "running", post.ai_status
    assert_equal "succeeded", post.metadata.dig("ai_pipeline", "steps", "visual", "status")
    assert_equal 12_345, post.metadata.dig("ai_pipeline", "steps", "visual", "result", "ai_analysis_id")

    enqueued = enqueued_jobs.map { |row| row[:job] }
    assert_includes enqueued, FinalizePostAnalysisPipelineJob
  end

  it "marks visual step failed and does not re-raise non-retryable runtime errors" do
    account, profile, post, run_id = build_pipeline_context

    runner = instance_double(Ai::Runner)
    allow(Ai::Runner).to receive(:new).with(account: account).and_return(runner)
    allow(runner).to receive(:analyze!).and_raise(TypeError, "AiAnalysis does not have #dig method")

    ProcessPostVisualAnalysisJob.perform_now(
      instagram_account_id: account.id,
      instagram_profile_id: profile.id,
      instagram_profile_post_id: post.id,
      pipeline_run_id: run_id
    )

    post.reload
    assert_equal "failed", post.metadata.dig("ai_pipeline", "steps", "visual", "status")
    assert_includes post.metadata.dig("ai_pipeline", "steps", "visual", "error").to_s, "TypeError"
    assert_equal "visual_analysis_failed", post.metadata.dig("ai_pipeline", "steps", "visual", "result", "reason")
  end

  it "skips stale visual jobs when pipeline is already terminal" do
    account, profile, post, run_id = build_pipeline_context
    metadata = post.metadata.deep_dup
    metadata["ai_pipeline"]["status"] = "failed"
    metadata["ai_pipeline"]["steps"]["visual"]["status"] = "failed"
    metadata["ai_pipeline"]["steps"]["visual"]["attempts"] = 6
    post.update!(metadata: metadata, ai_status: "failed")

    expect(Ai::Runner).not_to receive(:new)

    assert_no_enqueued_jobs only: FinalizePostAnalysisPipelineJob do
      ProcessPostVisualAnalysisJob.perform_now(
        instagram_account_id: account.id,
        instagram_profile_id: profile.id,
        instagram_profile_post_id: post.id,
        pipeline_run_id: run_id
      )
    end

    post.reload
    assert_equal "failed", post.metadata.dig("ai_pipeline", "status")
    assert_equal 6, post.metadata.dig("ai_pipeline", "steps", "visual", "attempts")
  end

  def build_pipeline_context
    account = InstagramAccount.create!(username: "acct_visual_#{SecureRandom.hex(4)}")
    profile = account.instagram_profiles.create!(username: "profile_visual_#{SecureRandom.hex(4)}", followers_count: 1800)
    post = profile.instagram_profile_posts.create!(
      instagram_account: account,
      shortcode: "visual_post_#{SecureRandom.hex(4)}",
      source_media_url: "https://cdn.example.com/post.jpg",
      ai_status: "pending"
    )
    post.media.attach(
      io: StringIO.new("\xFF\xD8\xFF\xE0valid-jpeg-body".b),
      filename: "visual.jpg",
      content_type: "image/jpeg"
    )

    pipeline_state = Ai::PostAnalysisPipelineState.new(post: post)
    run_id = pipeline_state.start!(
      source_job: self.class.name,
      task_flags: {
        analyze_visual: true,
        analyze_faces: false,
        run_ocr: false,
        run_video: false,
        run_metadata: false
      }
    )

    [ account, profile, post, run_id ]
  end
end
