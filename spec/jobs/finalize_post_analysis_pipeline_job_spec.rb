require "rails_helper"
require "securerandom"

RSpec.describe "FinalizePostAnalysisPipelineJobTest" do
  include ActiveJob::TestHelper

  before do
    clear_enqueued_jobs
    clear_performed_jobs
  end

  it "marks post analyzed when required pipeline steps are completed" do
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
          "status" => "running",
          "required_steps" => [ "visual" ],
          "steps" => {
            "visual" => {
              "status" => "succeeded",
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
end
