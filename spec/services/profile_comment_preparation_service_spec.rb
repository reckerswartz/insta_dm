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

  class FakeInsightStore
    attr_reader :calls

    def initialize
      @calls = []
    end

    def ingest_post!(profile:, post:, analysis:, metadata:)
      @calls << {
        profile_id: profile.id,
        post_id: post.id,
        has_analysis: analysis.is_a?(Hash),
        has_metadata: metadata.is_a?(Hash)
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
    insight_store = FakeInsightStore.new

    summary = Ai::ProfileCommentPreparationService.new(
      account: account,
      profile: profile,
      collector: FakeCollector.new(posts: posts),
      post_analyzer: ->(_post) { raise "post analyzer should not be called for analyzed posts" },
      user_profile_builder_service: user_profile_builder,
      face_identity_resolution_service: face_resolver,
      insight_store: insight_store
    ).prepare!(force: true)

    assert_equal true, summary["ready_for_comment_generation"]
    assert_equal "profile_context_ready", summary["reason_code"]
    assert_equal 3, summary.dig("analysis", "analyzed_posts_count")
    assert_equal true, summary.dig("identity_consistency", "consistent")
    assert_equal 1, user_profile_builder.refresh_calls
    assert_equal 3, face_resolver.calls.length
    assert_equal 3, insight_store.calls.length
    assert_equal 3, summary.dig("analysis", "insight_store_refreshed_posts_count")

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
      face_identity_resolution_service: FakeFaceIdentityResolver.new,
      insight_store: FakeInsightStore.new
    ).prepare!(force: true)

    assert_equal false, summary["ready_for_comment_generation"]
    assert_equal "primary_identity_not_linked_to_profile", summary["reason_code"]
    assert_equal false, summary.dig("identity_consistency", "consistent")
  end

  it "queues missing post analysis asynchronously when analyze_missing_posts is enabled" do
    account, profile = build_account_profile
    pending_post = InstagramProfilePost.create!(
      instagram_account: account,
      instagram_profile: profile,
      shortcode: "pending_#{SecureRandom.hex(4)}",
      taken_at: Time.current,
      ai_status: "failed",
      analyzed_at: nil,
      analysis: {},
      metadata: {}
    )

    queued_job = instance_double(ActiveJob::Base, job_id: "job_123", queue_name: "ai_visual_queue")
    allow(AnalyzeInstagramProfilePostJob).to receive(:perform_later).and_return(queued_job)

    summary = Ai::ProfileCommentPreparationService.new(
      account: account,
      profile: profile,
      collector: FakeCollector.new(posts: [ pending_post ]),
      user_profile_builder_service: FakeUserProfileBuilder.new,
      face_identity_resolution_service: FakeFaceIdentityResolver.new,
      insight_store: FakeInsightStore.new
    ).prepare!(force: true)

    expect(AnalyzeInstagramProfilePostJob).to have_received(:perform_later).with(
      hash_including(
        instagram_account_id: account.id,
        instagram_profile_id: profile.id,
        instagram_profile_post_id: pending_post.id,
        task_flags: hash_including(generate_comments: false)
      )
    )
    expect(summary.dig("analysis", "pending_posts_count")).to eq(1)
    expect(summary["ready_for_comment_generation"]).to eq(false)
    expect(summary["reason_code"]).to eq("latest_posts_not_analyzed")

    pending_post.reload
    expect(pending_post.ai_status).to eq("pending")
    expect(pending_post.metadata.dig("comment_preparation", "analysis_state")).to eq("queued")
    expect(pending_post.metadata.dig("comment_preparation", "analysis_job_id")).to eq("job_123")
  end
end
