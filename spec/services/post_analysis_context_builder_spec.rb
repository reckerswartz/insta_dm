require "rails_helper"
require "securerandom"

RSpec.describe Ai::PostAnalysisContextBuilder do
  it "skips corrupted image media based on signature validation" do
    account = InstagramAccount.create!(username: "acct_builder_#{SecureRandom.hex(4)}")
    profile = account.instagram_profiles.create!(username: "profile_builder_#{SecureRandom.hex(4)}")
    post = profile.instagram_profile_posts.create!(
      instagram_account: account,
      shortcode: "builder_post_#{SecureRandom.hex(4)}",
      source_media_url: nil
    )
    post.media.attach(
      io: StringIO.new(("not-a-real-jpeg-payload" * 40).b),
      filename: "corrupt.jpg",
      content_type: "image/jpeg"
    )

    payload = described_class.new(profile: profile, post: post).media_payload

    assert_equal "none", payload[:type]
    assert_equal "media_signature_invalid", payload[:reason]
    assert_equal "image/jpeg", payload[:content_type]
  end

  it "skips very large direct video analysis when no source URL exists" do
    stub_const("Ai::PostAnalysisContextBuilder::MAX_DIRECT_VIDEO_ANALYSIS_BYTES", 1024)

    account = InstagramAccount.create!(username: "acct_builder_vid_#{SecureRandom.hex(4)}")
    profile = account.instagram_profiles.create!(username: "profile_builder_vid_#{SecureRandom.hex(4)}")
    post = profile.instagram_profile_posts.create!(
      instagram_account: account,
      shortcode: "builder_vid_post_#{SecureRandom.hex(4)}",
      source_media_url: nil
    )
    post.media.attach(
      io: StringIO.new("....ftypisom....".b + ("a" * 1600).b),
      filename: "large.mp4",
      content_type: "video/mp4"
    )

    payload = described_class.new(profile: profile, post: post).media_payload

    assert_equal "none", payload[:type]
    assert_equal "video_too_large_for_direct_analysis", payload[:reason]
    assert_equal "video/mp4", payload[:content_type]
  end
end
