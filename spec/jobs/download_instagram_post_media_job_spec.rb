require "rails_helper"
require "securerandom"

RSpec.describe "DownloadInstagramPostMediaJobTest" do
  it "reuses saved post media across accounts by shortcode before downloading" do
    source_account = InstagramAccount.create!(username: "feed_src_#{SecureRandom.hex(4)}")
    source_profile = source_account.instagram_profiles.create!(
      username: "feed_src_profile_#{SecureRandom.hex(4)}",
      following: true
    )
    source_post = source_account.instagram_posts.create!(
      instagram_profile: source_profile,
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
    target_profile = target_account.instagram_profiles.create!(
      username: "feed_dst_profile_#{SecureRandom.hex(4)}",
      following: true
    )
    target_post = target_account.instagram_posts.create!(
      instagram_profile: target_profile,
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

  it "re-downloads feed post media when existing attached blob is corrupt on disk" do
    account = InstagramAccount.create!(username: "feed_corrupt_#{SecureRandom.hex(4)}")
    profile = account.instagram_profiles.create!(
      username: "feed_corrupt_profile_#{SecureRandom.hex(4)}",
      following: true
    )
    post = account.instagram_posts.create!(
      instagram_profile: profile,
      shortcode: "feed_corrupt_shortcode_1",
      detected_at: Time.current,
      media_url: "https://cdn.example.com/feed-corrupt.jpg"
    )
    post.media.attach(
      io: StringIO.new("\xFF\xD8\xFF\xE0original-feed".b),
      filename: "feed_original.jpg",
      content_type: "image/jpeg"
    )
    original_blob_id = post.media.blob.id
    path = post.media.blob.service.send(:path_for, post.media.blob.key)
    File.binwrite(path, "".b)

    replacement_io = StringIO.new("\xFF\xD8\xFF\xE0replacement-feed".b)
    replacement_io.set_encoding(Encoding::BINARY)

    job = DownloadInstagramPostMediaJob.new
    allow(job).to receive(:download).and_return([replacement_io, "image/jpeg", "feed_replacement.jpg"])

    job.perform(instagram_post_id: post.id)

    post.reload
    assert post.media.attached?
    refute_equal original_blob_id, post.media.blob.id
    assert_not_nil post.media_downloaded_at
    assert_equal true, post.media.blob.byte_size.positive?
  end

  it "skips feed media download when URL is promotional" do
    account = InstagramAccount.create!(username: "feed_promo_#{SecureRandom.hex(4)}")
    profile = account.instagram_profiles.create!(
      username: "feed_promo_profile_#{SecureRandom.hex(4)}",
      following: true
    )
    post = account.instagram_posts.create!(
      instagram_profile: profile,
      shortcode: "feed_promo_shortcode_1",
      detected_at: Time.current,
      media_url: "https://cdn.example.com/ad.jpg?campaign_id=987"
    )

    job = DownloadInstagramPostMediaJob.new
    allow(job).to receive(:download) do
      raise "download should not run for promotional URLs"
    end

    job.perform(instagram_post_id: post.id)

    post.reload
    refute post.media.attached?
    assert_nil post.media_downloaded_at
    assert_equal "skipped", post.metadata["download_status"]
    assert_equal "promotional_media_query", post.metadata["download_skip_reason"]
  end

  it "skips feed media download for profiles outside follow graph" do
    account = InstagramAccount.create!(username: "feed_outside_#{SecureRandom.hex(4)}")
    profile = account.instagram_profiles.create!(
      username: "feed_outside_profile_#{SecureRandom.hex(4)}",
      following: false,
      follows_you: false
    )
    post = account.instagram_posts.create!(
      instagram_profile: profile,
      shortcode: "feed_outside_shortcode_1",
      detected_at: Time.current,
      media_url: "https://cdn.example.com/regular.jpg"
    )

    job = DownloadInstagramPostMediaJob.new
    allow(job).to receive(:download) do
      raise "download should not run for out-of-network profiles"
    end

    job.perform(instagram_post_id: post.id)

    post.reload
    refute post.media.attached?
    assert_nil post.media_downloaded_at
    assert_equal "skipped", post.metadata["download_status"]
    assert_equal "profile_not_connected", post.metadata["download_skip_reason"]
  end
end
