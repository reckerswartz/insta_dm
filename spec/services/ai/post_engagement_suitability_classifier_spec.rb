require "rails_helper"
require "securerandom"

RSpec.describe Ai::PostEngagementSuitabilityClassifier do
  def build_profile_post(caption:, metadata:, analysis:, profile_tags: [])
    account = InstagramAccount.create!(username: "acct_#{SecureRandom.hex(4)}")
    profile = account.instagram_profiles.create!(username: "profile_#{SecureRandom.hex(4)}")
    Array(profile_tags).each do |tag_name|
      tag = ProfileTag.find_or_create_by!(name: tag_name.to_s)
      profile.profile_tags << tag unless profile.profile_tags.exists?(id: tag.id)
    end
    post = profile.instagram_profile_posts.create!(
      instagram_account: account,
      shortcode: "post_#{SecureRandom.hex(3)}",
      taken_at: Time.current,
      caption: caption,
      metadata: metadata,
      analysis: analysis
    )
    [ profile, post ]
  end

  it "marks explicit repost and quote content as unsuitable" do
    profile, post = build_profile_post(
      caption: "Repost via @origin_account - quote of the day",
      metadata: { "is_repost" => true },
      analysis: {
        "image_description" => "A quote card with text overlay.",
        "topics" => [ "quote", "text" ]
      }
    )

    result = described_class.new(
      profile: profile,
      post: post,
      analysis: post.analysis,
      metadata: post.metadata
    ).classify

    assert_equal false, result["engagement_suitable"]
    assert_equal "reshared", result["ownership"]
    assert_equal "quote", result["content_type"]
    assert_includes Array(result["reason_codes"]), "metadata_repost_flag"
  end

  it "keeps original personal content engagement-suitable" do
    profile, post = build_profile_post(
      caption: "My weekend hike with family was perfect.",
      metadata: {},
      analysis: {
        "image_description" => "A person hiking in the hills.",
        "topics" => [ "hike", "weekend", "family" ],
        "face_summary" => { "face_count" => 2, "owner_faces_count" => 1 }
      }
    )

    result = described_class.new(
      profile: profile,
      post: post,
      analysis: post.analysis,
      metadata: post.metadata
    ).classify

    assert_equal true, result["engagement_suitable"]
    assert_equal "original", result["ownership"]
    assert_equal "personal_post", result["content_type"]
    assert_includes Array(result["reason_codes"]), "same_profile_owner_content"
  end

  it "marks promotional posts as unsuitable" do
    profile, post = build_profile_post(
      caption: "Huge discount. Shop now. Link in bio.",
      metadata: {},
      analysis: {
        "image_description" => "A promotional offer poster.",
        "topics" => [ "offer", "discount" ]
      }
    )

    result = described_class.new(
      profile: profile,
      post: post,
      analysis: post.analysis,
      metadata: post.metadata
    ).classify

    assert_equal false, result["engagement_suitable"]
    assert_equal "promotional", result["content_type"]
    assert_includes Array(result["reason_codes"]), "promotional_content"
  end

  it "marks page-style generic content as unsuitable" do
    profile, post = build_profile_post(
      caption: "One word for this airport look? #instantbuzz #bollyupdates #celebnews #dailyfeed",
      metadata: {},
      analysis: {
        "image_description" => "Celebrity spotted at airport with crowd around.",
        "topics" => [ "celebrity", "airport" ],
        "hashtags" => [ "#instantbuzz", "#bollyupdates", "#celebnews", "#dailyfeed" ]
      },
      profile_tags: [ "page" ]
    )

    result = described_class.new(
      profile: profile,
      post: post,
      analysis: post.analysis,
      metadata: post.metadata
    ).classify

    assert_equal false, result["engagement_suitable"]
    assert_equal "generic_reshared", result["content_type"]
    assert_equal "original", result["ownership"]
    assert_includes Array(result["reason_codes"]), "page_profile_context"
  end
end
