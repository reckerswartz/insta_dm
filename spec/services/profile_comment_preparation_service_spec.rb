require "rails_helper"
require "securerandom"

RSpec.describe Ai::ProfileCommentPreparationService do
  class FakeCollector
    def initialize(posts:)
      @posts = posts
    end

    def collect_and_persist!(**_kwargs)
      { posts: @posts }
    end
  end

  class FakeUserProfileBuilder
    attr_reader :refresh_calls

    def initialize
      @refresh_calls = 0
    end

    def refresh!(profile:)
      @refresh_calls += 1
      profile
    end
  end

  class FakeFaceIdentityResolver
    attr_reader :calls

    def initialize
      @calls = []
    end

    def resolve_for_post!(post:, extracted_usernames:, content_summary:)
      @calls << {
        post_id: post.id,
        extracted_usernames: extracted_usernames,
        has_content_summary: content_summary.is_a?(Hash)
      }
    end
  end

  def build_account_profile
    account = InstagramAccount.create!(username: "acct_#{SecureRandom.hex(4)}")
    profile = InstagramProfile.create!(
      instagram_account: account,
      username: "profile_#{SecureRandom.hex(4)}",
      display_name: "Profile User",
      bio: "Creator and photographer"
    )
    [ account, profile ]
  end

  def create_analyzed_post(account:, profile:, shortcode:, analysis:)
    InstagramProfilePost.create!(
      instagram_account: account,
      instagram_profile: profile,
      shortcode: shortcode,
      taken_at: Time.current,
      ai_status: "analyzed",
      analyzed_at: Time.current,
      analysis: analysis,
      metadata: {}
    )
  end

  it "prepare returns ready when recent posts are analyzed with signals and identity is consistent" do
    account, profile = build_account_profile
    person = InstagramStoryPerson.create!(
      instagram_account: account,
      instagram_profile: profile,
      role: "primary_user",
      label: profile.username,
      appearance_count: 5,
      first_seen_at: 2.days.ago,
      last_seen_at: Time.current,
      metadata: { "linked_usernames" => [ profile.username ] }
    )

    posts = 3.times.map do |idx|
      post = create_analyzed_post(
        account: account,
        profile: profile,
        shortcode: "post_#{idx}_#{SecureRandom.hex(3)}",
        analysis: {
          "image_description" => "Photo #{idx}",
          "topics" => [ "fitness", "daily" ],
          "mentions" => [ "@#{profile.username}" ]
        }
      )
      InstagramPostFace.create!(
        instagram_profile_post: post,
        instagram_story_person: person,
        role: "primary_user"
      )
      post
    end

    user_profile_builder = FakeUserProfileBuilder.new
    face_resolver = FakeFaceIdentityResolver.new

    summary = Ai::ProfileCommentPreparationService.new(
      account: account,
      profile: profile,
      collector: FakeCollector.new(posts: posts),
      post_analyzer: ->(_post) { raise "post analyzer should not be called for analyzed posts" },
      user_profile_builder_service: user_profile_builder,
      face_identity_resolution_service: face_resolver
    ).prepare!(force: true)

    assert_equal true, summary["ready_for_comment_generation"]
    assert_equal "profile_context_ready", summary["reason_code"]
    assert_equal 3, summary.dig("analysis", "analyzed_posts_count")
    assert_equal true, summary.dig("identity_consistency", "consistent")
    assert_equal 1, user_profile_builder.refresh_calls
    assert_equal 3, face_resolver.calls.length

    behavior_profile = profile.instagram_profile_behavior_profile
    assert_not_nil behavior_profile
    assert_equal "profile_context_ready", behavior_profile.metadata.dig("comment_generation_preparation", "reason_code")
  end

  it "prepare returns not ready when primary identity does not map to profile username" do
    account, profile = build_account_profile
    other_person = InstagramStoryPerson.create!(
      instagram_account: account,
      instagram_profile: profile,
      role: "secondary_person",
      label: "other_user",
      appearance_count: 5,
      first_seen_at: 2.days.ago,
      last_seen_at: Time.current,
      metadata: { "linked_usernames" => [ "someone_else" ] }
    )

    posts = 3.times.map do |idx|
      post = create_analyzed_post(
        account: account,
        profile: profile,
        shortcode: "mismatch_#{idx}_#{SecureRandom.hex(3)}",
        analysis: {
          "image_description" => "Photo #{idx}",
          "topics" => [ "travel" ],
          "objects" => [ "person" ]
        }
      )
      InstagramPostFace.create!(
        instagram_profile_post: post,
        instagram_story_person: other_person,
        role: "secondary_person"
      )
      post
    end

    summary = Ai::ProfileCommentPreparationService.new(
      account: account,
      profile: profile,
      collector: FakeCollector.new(posts: posts),
      post_analyzer: ->(_post) { nil },
      user_profile_builder_service: FakeUserProfileBuilder.new,
      face_identity_resolution_service: FakeFaceIdentityResolver.new
    ).prepare!(force: true)

    assert_equal false, summary["ready_for_comment_generation"]
    assert_equal "primary_identity_not_linked_to_profile", summary["reason_code"]
    assert_equal false, summary.dig("identity_consistency", "consistent")
  end
end
