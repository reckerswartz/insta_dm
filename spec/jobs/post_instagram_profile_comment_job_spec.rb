require "rails_helper"
require "securerandom"

RSpec.describe PostInstagramProfileCommentJob do
  include ActiveJob::TestHelper

  it "does not post comments when engagement policy marks the post unsuitable" do
    account = InstagramAccount.create!(username: "acct_#{SecureRandom.hex(4)}")
    profile = account.instagram_profiles.create!(username: "profile_#{SecureRandom.hex(4)}")
    post = profile.instagram_profile_posts.create!(
      instagram_account: account,
      shortcode: "post_#{SecureRandom.hex(4)}",
      taken_at: Time.current,
      metadata: {
        "media_id" => "media_123",
        "comment_generation_policy" => {
          "status" => "blocked",
          "blocked_reason_code" => "unsuitable_for_engagement",
          "blocked_reason" => "Post is reshared quote content."
        }
      }
    )
    action_log = profile.instagram_profile_action_logs.create!(
      instagram_account: account,
      action: "post_comment",
      status: "queued",
      trigger_source: "rspec",
      occurred_at: Time.current
    )

    client = instance_double(Instagram::Client)
    allow(Instagram::Client).to receive(:new).and_return(client)
    expect(client).not_to receive(:post_comment_to_media!)

    expect do
      described_class.perform_now(
        instagram_account_id: account.id,
        instagram_profile_id: profile.id,
        instagram_profile_post_id: post.id,
        comment_text: "Nice post!",
        media_id: "media_123",
        profile_action_log_id: action_log.id
      )
    end.not_to change { profile.instagram_profile_events.where(kind: "post_comment_sent").count }

    action_log.reload
    assert_equal "failed", action_log.status
    assert_includes action_log.error_message.to_s, "reshared quote content"
  end

  it "does not post comments when ownership classification is reshared" do
    account = InstagramAccount.create!(username: "acct_#{SecureRandom.hex(4)}")
    profile = account.instagram_profiles.create!(username: "profile_#{SecureRandom.hex(4)}")
    post = profile.instagram_profile_posts.create!(
      instagram_account: account,
      shortcode: "post_#{SecureRandom.hex(4)}",
      taken_at: Time.current,
      metadata: {
        "media_id" => "media_reshared_123",
        "engagement_classification" => {
          "ownership" => "reshared",
          "same_profile_owner_content" => false,
          "engagement_suitable" => false,
          "summary" => "Reshared quote post."
        }
      }
    )
    action_log = profile.instagram_profile_action_logs.create!(
      instagram_account: account,
      action: "post_comment",
      status: "queued",
      trigger_source: "rspec",
      occurred_at: Time.current
    )

    client = instance_double(Instagram::Client)
    allow(Instagram::Client).to receive(:new).and_return(client)
    expect(client).not_to receive(:post_comment_to_media!)

    described_class.perform_now(
      instagram_account_id: account.id,
      instagram_profile_id: profile.id,
      instagram_profile_post_id: post.id,
      comment_text: "Nice post!",
      media_id: "media_reshared_123",
      profile_action_log_id: action_log.id
    )

    action_log.reload
    assert_equal "failed", action_log.status
    assert_includes action_log.error_message.to_s, "ownership"
  end
end
