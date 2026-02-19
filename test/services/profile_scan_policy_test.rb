require "test_helper"
require "securerandom"

class ProfileScanPolicyTest < ActiveSupport::TestCase
  test "skips scan when followers exceed threshold" do
    account = InstagramAccount.create!(username: "acct_#{SecureRandom.hex(4)}")
    profile = account.instagram_profiles.create!(
      username: "profile_#{SecureRandom.hex(4)}",
      followers_count: 25_001
    )

    decision = Instagram::ProfileScanPolicy.new(profile: profile).decision

    assert_equal true, decision[:skip_scan]
    assert_equal true, decision[:skip_post_analysis]
    assert_equal "followers_threshold_exceeded", decision[:reason_code]
  end

  test "skips likely meme/info pages when not personal-tagged" do
    account = InstagramAccount.create!(username: "acct_#{SecureRandom.hex(4)}")
    profile = account.instagram_profiles.create!(
      username: "daily_memes_hub_#{SecureRandom.hex(2)}",
      display_name: "Daily Meme Quotes",
      bio: "Funny meme page with daily facts and viral news."
    )

    decision = Instagram::ProfileScanPolicy.new(profile: profile).decision

    assert_equal true, decision[:skip_scan]
    assert_equal "non_personal_profile_page", decision[:reason_code]
  end

  test "allows scan for personal-tagged profiles even with meme-like bio" do
    account = InstagramAccount.create!(username: "acct_#{SecureRandom.hex(4)}")
    profile = account.instagram_profiles.create!(
      username: "creator_#{SecureRandom.hex(2)}",
      display_name: "Meme Creator",
      bio: "memes and jokes"
    )
    personal_tag = ProfileTag.find_or_create_by!(name: "personal_user")
    profile.profile_tags << personal_tag

    decision = Instagram::ProfileScanPolicy.new(profile: profile).decision

    assert_equal false, decision[:skip_scan]
    assert_equal "scan_allowed", decision[:reason_code]
  end
end
