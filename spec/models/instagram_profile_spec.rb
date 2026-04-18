require "rails_helper"

RSpec.describe InstagramProfile, type: :model do
  let(:account) { InstagramAccount.create!(username: "acct_#{SecureRandom.hex(4)}") }

  def build_profile(**attrs)
    account.instagram_profiles.create!(
      username: "profile_#{SecureRandom.hex(4)}",
      **attrs
    )
  end

  def tag_profile!(profile, *names)
    names.each do |name|
      tag = ProfileTag.find_or_create_by!(name: name.to_s)
      profile.profile_tags << tag unless profile.profile_tags.exists?(id: tag.id)
    end
  end

  describe "#likely_page?" do
    it "is false for a plain personal-looking profile" do
      profile = build_profile(followers_count: 250)
      expect(profile.likely_page?).to eq(false)
    end

    it "is true when is_business is set" do
      profile = build_profile(is_business: true, followers_count: 30)
      expect(profile.likely_page?).to eq(true)
    end

    it "is true when is_verified is set" do
      profile = build_profile(is_verified: true, followers_count: 30)
      expect(profile.likely_page?).to eq(true)
    end

    it "is true when follower count exceeds LIKELY_PAGE_FOLLOWER_THRESHOLD" do
      profile = build_profile(followers_count: described_class::LIKELY_PAGE_FOLLOWER_THRESHOLD + 1)
      expect(profile.likely_page?).to eq(true)
    end

    it "is true when a page-style tag is attached even if is_business/is_verified are false" do
      profile = build_profile(followers_count: 200)
      tag_profile!(profile, "brand")
      expect(profile.likely_page?).to eq(true)
    end
  end

  describe "#friend_tagged? / #skip_tagged?" do
    it "friend_tagged? is true for any of the FRIEND_PROFILE_TAGS" do
      profile = build_profile
      tag_profile!(profile, "female_friend")
      expect(profile.friend_tagged?).to eq(true)
      expect(profile.skip_tagged?).to eq(false)
    end

    it "skip_tagged? picks up both explicit exclusion tags" do
      profile = build_profile
      tag_profile!(profile, "engagement_excluded")
      expect(profile.skip_tagged?).to eq(true)

      other = build_profile
      tag_profile!(other, "profile_scan_excluded")
      expect(other.skip_tagged?).to eq(true)
    end

    it "is false when no engagement-related tag is present" do
      profile = build_profile
      tag_profile!(profile, "automatic_reply")
      expect(profile.friend_tagged?).to eq(false)
      expect(profile.skip_tagged?).to eq(false)
    end
  end

  describe "#engagement_eligibility" do
    it "returns eligible / neutral priority for a plain personal profile" do
      profile = build_profile(followers_count: 120)
      eligibility = profile.engagement_eligibility
      expect(eligibility.eligible?).to eq(true)
      expect(eligibility.priority).to eq(0)
      expect(eligibility.reason).to be_nil
    end

    it "returns eligible / friend priority for a friend-tagged profile" do
      profile = build_profile(followers_count: 120)
      tag_profile!(profile, "friend")
      expect(profile.engagement_eligibility.priority).to eq(1)
    end

    it "returns not eligible with reason profile_likely_page for a business profile" do
      profile = build_profile(is_business: true, followers_count: 80)
      eligibility = profile.engagement_eligibility
      expect(eligibility.eligible?).to eq(false)
      expect(eligibility.reason).to eq("profile_likely_page")
    end

    it "returns not eligible with reason profile_skip_tagged when the operator skip tag is set, even on a friend" do
      # Phase 11 invariant: an operator "never engage" tag wins over the
      # friend priority tag. This prevents the auto-reply pipeline from
      # surfacing someone you've explicitly silenced.
      profile = build_profile(followers_count: 120)
      tag_profile!(profile, "friend", "engagement_excluded")
      eligibility = profile.engagement_eligibility
      expect(eligibility.eligible?).to eq(false)
      expect(eligibility.reason).to eq("profile_skip_tagged")
    end
  end
end
