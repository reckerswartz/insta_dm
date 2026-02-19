require "rails_helper"
require "securerandom"

RSpec.describe "GenerateLlmCommentJobTest" do
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
end
