require "rails_helper"
require "securerandom"

RSpec.describe "AnalyzeInstagramProfilePostJobTest" do
  it "marks post as policy-skipped for high-follower profiles" do
    account = InstagramAccount.create!(username: "acct_#{SecureRandom.hex(4)}")
    profile = account.instagram_profiles.create!(
      username: "profile_#{SecureRandom.hex(4)}",
      followers_count: 30_000
    )
    post = profile.instagram_profile_posts.create!(
      instagram_account: account,
      shortcode: "post_#{SecureRandom.hex(3)}",
      ai_status: "pending"
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
end
