require "rails_helper"
require "securerandom"

RSpec.describe ProcessPostMetadataTaggingJob do
  include ActiveJob::TestHelper

  before do
    clear_enqueued_jobs
    clear_performed_jobs
    allow(Ai::ProfileAutoTagger).to receive(:sync_from_post_analysis!)
  end

  it "enqueues async comment generation after metadata tagging" do
    account, profile, post, run_id = build_metadata_pipeline_post(
      task_flags: {
        "run_metadata" => true,
        "generate_comments" => true,
        "enforce_comment_evidence_policy" => true,
        "retry_on_incomplete_profile" => true
      }
    )

    expect do
      described_class.perform_now(
        instagram_account_id: account.id,
        instagram_profile_id: profile.id,
        instagram_profile_post_id: post.id,
        pipeline_run_id: run_id
      )
    end.to have_enqueued_job(GeneratePostCommentSuggestionsJob).with(
      hash_including(
        instagram_account_id: account.id,
        instagram_profile_id: profile.id,
        instagram_profile_post_id: post.id,
        source_step: "metadata"
      )
    )

    post.reload
    expect(post.metadata.dig("ai_pipeline", "steps", "metadata", "status")).to eq("succeeded")
    expect(post.metadata.dig("ai_pipeline", "steps", "metadata", "result", "comment_job_queued")).to eq(true)
    expect(post.analysis.dig("face_summary", "face_count")).to eq(2)
    expect(Ai::ProfileAutoTagger).to have_received(:sync_from_post_analysis!).with(
      hash_including(profile: profile)
    )
  end

  it "skips async comment generation enqueue when comments are disabled by task flags" do
    account, profile, post, run_id = build_metadata_pipeline_post(
      task_flags: {
        "run_metadata" => true,
        "generate_comments" => false
      }
    )

    expect do
      described_class.perform_now(
        instagram_account_id: account.id,
        instagram_profile_id: profile.id,
        instagram_profile_post_id: post.id,
        pipeline_run_id: run_id
      )
    end.not_to have_enqueued_job(GeneratePostCommentSuggestionsJob)

    post.reload
    expect(post.metadata.dig("ai_pipeline", "steps", "metadata", "status")).to eq("succeeded")
    expect(post.metadata.dig("ai_pipeline", "steps", "metadata", "result", "comment_generation_status")).to eq("disabled_by_task_flags")
    expect(post.metadata.dig("ai_pipeline", "steps", "metadata", "result", "comment_job_queued")).to eq(false)
  end

  def build_metadata_pipeline_post(task_flags:)
    account = InstagramAccount.create!(username: "acct_#{SecureRandom.hex(4)}")
    profile = account.instagram_profiles.create!(
      username: "profile_#{SecureRandom.hex(4)}",
      followers_count: 500
    )
    post = profile.instagram_profile_posts.create!(
      instagram_account: account,
      shortcode: "post_#{SecureRandom.hex(4)}",
      ai_status: "running",
      analysis: { "image_description" => "A photo with people." },
      metadata: {}
    )

    run_id = SecureRandom.uuid
    post.update!(
      metadata: {
        "face_recognition" => {
          "face_count" => 2,
          "matched_people" => [
            { "owner_match" => true, "recurring_face" => true },
            { "owner_match" => false, "recurring_face" => false }
          ]
        },
        "ai_pipeline" => {
          "run_id" => run_id,
          "status" => "running",
          "task_flags" => task_flags,
          "required_steps" => [ "metadata" ],
          "steps" => {
            "visual" => { "status" => "skipped", "attempts" => 0, "result" => {} },
            "face" => { "status" => "skipped", "attempts" => 0, "result" => {} },
            "ocr" => { "status" => "skipped", "attempts" => 0, "result" => {} },
            "video" => { "status" => "skipped", "attempts" => 0, "result" => {} },
            "metadata" => { "status" => "pending", "attempts" => 0, "result" => {} }
          }
        }
      }
    )

    [ account, profile, post, run_id ]
  end
end
