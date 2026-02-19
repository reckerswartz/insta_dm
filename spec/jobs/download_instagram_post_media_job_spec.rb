require "rails_helper"
require "securerandom"

RSpec.describe "DownloadInstagramPostMediaJobTest" do
  it "reuses saved post media across accounts by shortcode before downloading" do
    source_account = InstagramAccount.create!(username: "feed_src_#{SecureRandom.hex(4)}")
    source_post = source_account.instagram_posts.create!(
      shortcode: "shared_shortcode_1",
      detected_at: 1.minute.ago,
      media_url: "https://cdn.example.com/source.jpg"
    )
    source_post.media.attach(
      io: StringIO.new("existing-feed-media"),
      filename: "source.jpg",
      content_type: "image/jpeg"
    )
    source_post.update!(media_downloaded_at: Time.current)

    target_account = InstagramAccount.create!(username: "feed_dst_#{SecureRandom.hex(4)}")
    target_post = target_account.instagram_posts.create!(
      shortcode: "shared_shortcode_1",
      detected_at: Time.current,
      media_url: "https://cdn.example.com/target.jpg?token=abc"
    )

    expect_any_instance_of(DownloadInstagramPostMediaJob).not_to receive(:download)

    DownloadInstagramPostMediaJob.perform_now(instagram_post_id: target_post.id)

    target_post.reload
    assert target_post.media.attached?
    assert_not_nil target_post.media_downloaded_at
    assert_equal source_post.media.blob.id, target_post.media.blob.id
  end
end
