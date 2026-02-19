require "rails_helper"
require "securerandom"

RSpec.describe "GenerateLlmCommentJobTest" do
  include ActiveJob::TestHelper

  before do
    clear_enqueued_jobs
    clear_performed_jobs
  end

  def build_story_event
    account = InstagramAccount.create!(username: "acct_#{SecureRandom.hex(4)}")
    profile = InstagramProfile.create!(
      instagram_account: account,
      username: "profile_#{SecureRandom.hex(4)}"
    )
    event = InstagramProfileEvent.create!(
      instagram_profile: profile,
      kind: "story_downloaded",
      external_id: "event_#{SecureRandom.hex(4)}",
      detected_at: Time.current,
      metadata: {}
    )
    [ account, profile, event ]
  end
  it "skips generation when profile preparation is not ready and stores preparation snapshot" do
    _account, _profile, event = build_story_event
    summary = {
      "ready_for_comment_generation" => false,
      "reason_code" => "identity_consistency_not_confirmed",
      "reason" => "Identity consistency could not be confirmed."
    }
    fake_service = Struct.new(:result) do
      def prepare!
        result
      end
    end.new(summary)

    job = GenerateLlmCommentJob.new
    job.define_singleton_method(:prepare_profile_context) do |profile:, account:|
      fake_service.prepare!
    end

    assert_nothing_raised do
      job.perform(
        instagram_profile_event_id: event.id,
        provider: "local",
        requested_by: "test"
      )
    end

    event.reload
    assert_equal "skipped", event.llm_comment_status
    assert_match(/Identity consistency could not be confirmed/i, event.llm_comment_last_error.to_s)
    assert_equal(
      "identity_consistency_not_confirmed",
      event.llm_comment_metadata.dig("profile_comment_preparation", "reason_code")
    )
    assert_equal false, event.llm_comment_metadata.dig("profile_comment_preparation", "ready_for_comment_generation")
    assert_equal "profile_comment_preparation", event.llm_comment_metadata.dig("last_failure", "source")
  end

  it "requeues generation after a delay when profile preparation is incomplete" do
    _account, _profile, event = build_story_event
    summary = {
      "ready_for_comment_generation" => false,
      "reason_code" => "latest_posts_not_analyzed",
      "reason" => "Latest posts have not been fully analyzed yet."
    }

    job = GenerateLlmCommentJob.new
    job.define_singleton_method(:prepare_profile_context) do |profile:, account:|
      summary
    end

    assert_enqueued_with(job: GenerateLlmCommentJob) do
      job.perform(
        instagram_profile_event_id: event.id,
        provider: "local",
        requested_by: "test"
      )
    end

    event.reload
    assert_equal "queued", event.llm_comment_status
    assert_not_nil event.llm_comment_job_id
    assert_equal 1, event.llm_comment_metadata.dig("profile_preparation_retry", "attempts").to_i
    assert_equal "latest_posts_not_analyzed", event.llm_comment_metadata.dig("profile_preparation_retry", "last_reason_code")
  end
end
