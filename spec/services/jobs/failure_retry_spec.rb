require "rails_helper"
require "securerandom"

RSpec.describe Jobs::FailureRetry do
  include ActiveJob::TestHelper

  before do
    clear_enqueued_jobs
    clear_performed_jobs
  end

  it "skips automatic retry when post-analysis pipeline is already terminal" do
    failure = build_visual_failure(pipeline_status: "failed", visual_status: "failed")

    result = nil
    assert_no_enqueued_jobs do
      result = described_class.enqueue_automatic_retries!(limit: 5, max_attempts: 3, cooldown: 0.minutes)
    end

    assert_equal 0, result[:enqueued]
    assert_operator result[:skipped], :>=, 1

    failure.reload
    assert_equal 0, failure.metadata.dig("retry_state", "attempts").to_i
  end

  it "enqueues automatic retry when post-analysis pipeline is still active" do
    failure = build_visual_failure(pipeline_status: "running", visual_status: "pending")

    result = described_class.enqueue_automatic_retries!(limit: 5, max_attempts: 3, cooldown: 0.minutes)

    assert_equal 1, result[:enqueued]
    enqueued = enqueued_jobs.find { |row| row[:job] == ProcessPostVisualAnalysisJob }
    assert enqueued
    enqueued_args = Array(enqueued[:args]).first
    assert_equal failure.instagram_account_id, enqueued_args.to_h.with_indifferent_access[:instagram_account_id]

    failure.reload
    assert_equal 1, failure.metadata.dig("retry_state", "attempts").to_i
  end

  def build_visual_failure(pipeline_status:, visual_status:)
    account = InstagramAccount.create!(username: "acct_retry_#{SecureRandom.hex(4)}")
    profile = account.instagram_profiles.create!(username: "profile_retry_#{SecureRandom.hex(4)}", followers_count: 450)
    post = profile.instagram_profile_posts.create!(
      instagram_account: account,
      shortcode: "retry_post_#{SecureRandom.hex(4)}",
      ai_status: "pending",
      metadata: {}
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

    metadata = post.metadata.deep_dup
    metadata["ai_pipeline"]["status"] = pipeline_status.to_s
    metadata["ai_pipeline"]["steps"]["visual"]["status"] = visual_status.to_s
    post.update!(metadata: metadata)

    BackgroundJobFailure.create!(
      active_job_id: SecureRandom.uuid,
      queue_name: "ai_visual_queue",
      job_class: "ProcessPostVisualAnalysisJob",
      arguments_json: JSON.generate(
        [
          {
            instagram_account_id: account.id,
            instagram_profile_id: profile.id,
            instagram_profile_post_id: post.id,
            pipeline_run_id: run_id
          }
        ]
      ),
      instagram_account_id: account.id,
      instagram_profile_id: profile.id,
      error_class: "TypeError",
      error_message: "AiAnalysis does not have #dig method",
      failure_kind: "runtime",
      retryable: true,
      occurred_at: Time.current,
      metadata: {
        retry_state: {
          attempts: 0
        }
      }
    )
  end
end
