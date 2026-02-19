require "rails_helper"
require "securerandom"

RSpec.describe "DownloadInstagramProfileAvatarJobTest" do
  it "skips invalid placeholder avatar url without failing the action log" do
    account = InstagramAccount.create!(username: "acct_#{SecureRandom.hex(6)}")
    profile = account.instagram_profiles.create!(
      username: "profile_#{SecureRandom.hex(6)}",
      profile_pic_url: "/static/images/profile/profile-pic-null_outline_56_light-4x.png/bc91e9cae98c.png"
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
end
