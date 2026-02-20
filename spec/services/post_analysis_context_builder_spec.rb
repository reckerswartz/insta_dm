require "rails_helper"
require "securerandom"
require "tempfile"

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
    account = InstagramAccount.create!(username: "acct_builder_vid_#{SecureRandom.hex(4)}")
    profile = account.instagram_profiles.create!(username: "profile_builder_vid_#{SecureRandom.hex(4)}")
    post = profile.instagram_profile_posts.create!(
      instagram_account: account,
      shortcode: "builder_vid_post_#{SecureRandom.hex(4)}",
      source_media_url: nil
    )
    target_size = Ai::PostAnalysisContextBuilder::MAX_DIRECT_VIDEO_ANALYSIS_BYTES + 256
    Tempfile.create([ "large-video-test", ".mp4" ]) do |file|
      file.binmode
      file.write("....ftypisom....".b)
      written = "....ftypisom....".bytesize
      while written < target_size
        chunk_size = [16 * 1024, target_size - written].min
        file.write("a" * chunk_size)
        written += chunk_size
      end
      file.rewind

      post.media.attach(
        io: file,
        filename: "large.mp4",
        content_type: "video/mp4"
      )
    end

    payload = described_class.new(profile: profile, post: post).media_payload

    assert_equal "none", payload[:type]
    assert_equal "video_too_large_for_direct_analysis", payload[:reason]
    assert_equal "video/mp4", payload[:content_type]
  end
end
