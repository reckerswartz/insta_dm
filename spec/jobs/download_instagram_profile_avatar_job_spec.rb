require "rails_helper"
require "securerandom"

RSpec.describe "DownloadInstagramProfileAvatarJobTest" do
  it "skips invalid placeholder avatar url without failing the action log" do
    account = InstagramAccount.create!(username: "acct_#{SecureRandom.hex(6)}")
    profile = account.instagram_profiles.create!(
      username: "profile_#{SecureRandom.hex(6)}",
      profile_pic_url: "/static/images/profile/profile-pic-null_outline_56_light-4x.png/bc91e9cae98c.png",
      following: true
    )

    job = DownloadInstagramProfileAvatarJob.new
    job.define_singleton_method(:fetch_url) do |_url, **_kwargs|
      raise "fetch_url should not be called for invalid placeholder URLs"
    end

    assert_nothing_raised do
      job.perform(
        instagram_account_id: account.id,
        instagram_profile_id: profile.id,
        broadcast: false,
        force: false
      )
    end

    profile.reload
    log = profile.instagram_profile_action_logs.order(id: :desc).first

    assert_not_nil log
    assert_equal "succeeded", log.status
    assert_nil profile.profile_pic_url
    assert_nil profile.avatar_url_fingerprint
  end

  it "replaces an existing avatar without deleting attachment rows referenced by ingestion records" do
    account = InstagramAccount.create!(username: "acct_#{SecureRandom.hex(6)}")
    old_url = "https://cdn.example.com/avatar_old.jpg"
    new_url = "https://cdn.example.com/avatar_new.jpg"
    profile = account.instagram_profiles.create!(
      username: "profile_#{SecureRandom.hex(6)}",
      profile_pic_url: old_url,
      following: true
    )
    profile.avatar.attach(
      io: StringIO.new("old-avatar"),
      filename: "old.jpg",
      content_type: "image/jpeg"
    )
    old_attachment_id = profile.avatar_attachment&.id
    profile.update!(avatar_url_fingerprint: Digest::SHA256.hexdigest("cdn.example.com/avatar_old.jpg"), profile_pic_url: new_url)

    job = DownloadInstagramProfileAvatarJob.new
    job.define_singleton_method(:fetch_url) do |_url, **_kwargs|
      [StringIO.new("new-avatar"), "new.jpg", "image/jpeg"]
    end

    assert_nothing_raised do
      job.perform(
        instagram_account_id: account.id,
        instagram_profile_id: profile.id,
        broadcast: false,
        force: false
      )
    end

    profile.reload
    log = profile.instagram_profile_action_logs.order(id: :desc).first

    assert_not_nil old_attachment_id
    assert_not_nil profile.avatar_attachment
    assert_equal old_attachment_id, profile.avatar_attachment.id
    assert_equal "new-avatar", profile.avatar.download
    assert_equal Digest::SHA256.hexdigest("cdn.example.com/avatar_new.jpg"), profile.avatar_url_fingerprint
    assert_not_nil log
    assert_equal "succeeded", log.status
    assert_equal 1, ActiveStorageIngestion.where(active_storage_attachment_id: old_attachment_id).count
  end

  it "skips avatar download when profile is not connected" do
    account = InstagramAccount.create!(username: "acct_#{SecureRandom.hex(6)}")
    profile = account.instagram_profiles.create!(
      username: "outside_network_#{SecureRandom.hex(6)}",
      profile_pic_url: "https://cdn.example.com/not_connected.jpg",
      following: false,
      follows_you: false
    )

    job = DownloadInstagramProfileAvatarJob.new
    job.define_singleton_method(:fetch_url) do |_url, **_kwargs|
      raise "fetch_url should not be called for unconnected profiles"
    end

    assert_nothing_raised do
      job.perform(
        instagram_account_id: account.id,
        instagram_profile_id: profile.id,
        broadcast: false,
        force: false
      )
    end

    profile.reload
    log = profile.instagram_profile_action_logs.order(id: :desc).first

    refute profile.avatar.attached?
    assert_not_nil log
    assert_equal "succeeded", log.status
    assert_equal "profile_not_connected", log.metadata["reason"]
  end

  it "skips avatar download when avatar URL is promotional" do
    account = InstagramAccount.create!(username: "acct_#{SecureRandom.hex(6)}")
    profile = account.instagram_profiles.create!(
      username: "connected_profile_#{SecureRandom.hex(6)}",
      profile_pic_url: "https://cdn.example.com/avatar.jpg?utm_source=instagram_ads",
      following: true
    )

    job = DownloadInstagramProfileAvatarJob.new
    job.define_singleton_method(:fetch_url) do |_url, **_kwargs|
      raise "fetch_url should not be called for blocked promotional URLs"
    end

    assert_nothing_raised do
      job.perform(
        instagram_account_id: account.id,
        instagram_profile_id: profile.id,
        broadcast: false,
        force: false
      )
    end

    profile.reload
    log = profile.instagram_profile_action_logs.order(id: :desc).first

    refute profile.avatar.attached?
    assert_not_nil log
    assert_equal "succeeded", log.status
    assert_equal "promotional_media_query", log.metadata["reason"]
  end
end
