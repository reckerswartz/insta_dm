require "rails_helper"
require "securerandom"

RSpec.describe "InstagramClientCommentGenerationGateTest" do
  it "post comment suggestions are blocked when profile preparation is not ready" do
    account = InstagramAccount.create!(username: "acct_#{SecureRandom.hex(4)}")
    profile = InstagramProfile.create!(instagram_account: account, username: "profile_#{SecureRandom.hex(4)}")
    client = Instagram::Client.new(account: account)

    client.define_singleton_method(:ensure_profile_comment_generation_readiness) do |profile:|
      {
        "ready_for_comment_generation" => false,
        "reason_code" => "latest_posts_not_analyzed",
        "reason" => "Latest posts are not analyzed yet."
      }
    end

    client.define_singleton_method(:generate_google_engagement_comments!) do |**_kwargs|
      raise "should not call fallback generation when preparation is not ready"
    end
    client.define_singleton_method(:log_automation_event) do |**_kwargs|
      nil
    end

    suggestions = client.send(
      :generate_comment_suggestions_from_analysis!,
      profile: profile,
      payload: { post: { shortcode: "x" } },
      analysis: { "comment_suggestions" => [ "Looks good" ] }
    )

    assert_equal [], suggestions
  end
end
