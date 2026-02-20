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
  it "proceeds with generation even when profile preparation is not ready and stores preparation snapshot" do
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

    # Mock the comment generation to avoid actual AI calls
    allow(event).to receive(:generate_llm_comment!).and_return({
      status: "completed",
      selected_comment: "Test comment",
      relevance_score: 0.8
    })

    assert_nothing_raised do
      job.perform(
        instagram_profile_event_id: event.id,
        provider: "local",
        requested_by: "test"
      )
    end

    event.reload
    assert_equal "completed", event.llm_comment_status
    assert_equal(
      "identity_consistency_not_confirmed",
      event.llm_comment_metadata.dig("profile_comment_preparation", "reason_code")
    )
    assert_equal false, event.llm_comment_metadata.dig("profile_comment_preparation", "ready_for_comment_generation")
  end

  it "proceeds with generation when profile preparation is incomplete without fallback" do
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

    # Mock's comment generation to avoid actual AI calls
    allow(event).to receive(:generate_llm_comment!).and_return({
      status: "completed",
      selected_comment: "Test comment",
      relevance_score: 0.8
    })

    assert_no_enqueued_jobs do
      job.perform(
        instagram_profile_event_id: event.id,
        provider: "local",
        requested_by: "test"
      )
    end

    event.reload
    assert_equal "completed", event.llm_comment_status
    assert_equal(
      "latest_posts_not_analyzed",
      event.llm_comment_metadata.dig("profile_comment_preparation", "reason_code")
    )
  end
end
