require "rails_helper"

RSpec.describe "ProfileAnalysisCollectorTest" do
  it "marks missing posts as deleted and restores when they reappear" do
    account = InstagramAccount.create!(username: "collector_test_account")
    profile = account.instagram_profiles.create!(username: "collector_profile")

    existing_kept = profile.instagram_profile_posts.create!(
      instagram_account: account,
      shortcode: "keep_1",
      caption: "keep",
      likes_count: 10,
      comments_count: 1,
      metadata: {},
      last_synced_at: 1.day.ago
    )
    existing_deleted_candidate = profile.instagram_profile_posts.create!(
      instagram_account: account,
      shortcode: "old_1",
      caption: "old",
      likes_count: 3,
      comments_count: 0,
      metadata: {},
      last_synced_at: 1.day.ago
    )

    first_dataset = {
      profile: {},
      posts: [
        {
          shortcode: "keep_1",
          taken_at: Time.current,
          caption: "keep updated",
          permalink: "https://instagram.com/p/keep_1/",
          media_url: nil,
          image_url: nil,
          likes_count: 11,
          comments_count: 2,
          comments: []
        },
        {
          shortcode: "new_1",
          taken_at: Time.current,
          caption: "new post",
          permalink: "https://instagram.com/p/new_1/",
          media_url: nil,
          image_url: nil,
          likes_count: 1,
          comments_count: 0,
          comments: []
        }
      ]
    }

    client_stub = Object.new
    client_stub.define_singleton_method(:fetch_profile_analysis_dataset!) { |**_kwargs| first_dataset }

    with_client_stub(client_stub) do
      result = Instagram::ProfileAnalysisCollector.new(account: account, profile: profile).collect_and_persist!(
        posts_limit: nil,
        comments_limit: 8,
        track_missing_as_deleted: true,
        sync_source: "test_capture"
      )

      assert_equal 1, result.dig(:summary, :created_count)
      assert_equal 1, result.dig(:summary, :deleted_count)
      assert_includes result.dig(:summary, :deleted_shortcodes), "old_1"
    end

    existing_deleted_candidate.reload
    assert_equal true, ActiveModel::Type::Boolean.new.cast(existing_deleted_candidate.metadata["deleted_from_source"])

    second_dataset = {
      profile: {},
      posts: [
        {
          shortcode: "keep_1",
          taken_at: Time.current,
          caption: "keep updated again",
          permalink: "https://instagram.com/p/keep_1/",
          media_url: nil,
          image_url: nil,
          likes_count: 12,
          comments_count: 2,
          comments: []
        },
        {
          shortcode: "old_1",
          taken_at: Time.current,
          caption: "old restored",
          permalink: "https://instagram.com/p/old_1/",
          media_url: nil,
          image_url: nil,
          likes_count: 4,
          comments_count: 0,
          comments: []
        }
      ]
    }

    second_client_stub = Object.new
    second_client_stub.define_singleton_method(:fetch_profile_analysis_dataset!) { |**_kwargs| second_dataset }

    with_client_stub(second_client_stub) do
      result = Instagram::ProfileAnalysisCollector.new(account: account, profile: profile).collect_and_persist!(
        posts_limit: nil,
        comments_limit: 8,
        track_missing_as_deleted: true,
        sync_source: "test_capture"
      )

      assert_equal 1, result.dig(:summary, :restored_count)
      assert_includes result.dig(:summary, :restored_shortcodes), "old_1"
    end

    existing_kept.reload
    existing_deleted_candidate.reload
    assert_not ActiveModel::Type::Boolean.new.cast(existing_kept.metadata["deleted_from_source"])
    assert_not ActiveModel::Type::Boolean.new.cast(existing_deleted_candidate.metadata["deleted_from_source"])
    assert profile.instagram_profile_posts.exists?(shortcode: "new_1")
  end
  it "skips media re-download when media_id is unchanged" do
    account = InstagramAccount.create!(username: "collector_dedupe_account")
    profile = account.instagram_profiles.create!(username: "collector_dedupe_profile")

    post = profile.instagram_profile_posts.create!(
      instagram_account: account,
      shortcode: "same_media_1",
      caption: "existing",
      permalink: "https://instagram.com/p/same_media_1/",
      source_media_url: "https://cdn.example.com/old.jpg",
      likes_count: 5,
      comments_count: 0,
      metadata: { "media_id" => "media_123", "media_type" => 1 },
      media_url_fingerprint: "old-fingerprint",
      last_synced_at: 1.day.ago
    )
    post.media.attach(
      io: StringIO.new("existing-image"),
      filename: "existing.jpg",
      content_type: "image/jpeg"
    )

    dataset = {
      profile: {},
      posts: [
        {
          shortcode: "same_media_1",
          media_id: "media_123",
          media_type: 1,
          taken_at: Time.current,
          caption: "existing",
          permalink: "https://instagram.com/p/same_media_1/",
          media_url: "https://cdn.example.com/new-signed-url.jpg?token=abc",
          image_url: nil,
          likes_count: 5,
          comments_count: 0,
          comments: []
        }
      ]
    }

    client_stub = Object.new
    client_stub.define_singleton_method(:fetch_profile_analysis_dataset!) { |**_kwargs| dataset }

    download_called = false
    with_client_stub(client_stub) do
      collector = Instagram::ProfileAnalysisCollector.new(account: account, profile: profile)
      collector.define_singleton_method(:download_media) do |_url|
        download_called = true
        raise "download_media should not be called for unchanged media_id"
      end

      collector.collect_and_persist!(
        posts_limit: nil,
        comments_limit: 8,
        track_missing_as_deleted: false,
        sync_source: "test_capture"
      )
    end

    assert_equal false, download_called
    assert post.reload.media.attached?
    assert_equal "media_123", post.metadata["media_id"]
  end
  it "marks updated post as analysis candidate when analysis inputs change" do
    account = InstagramAccount.create!(username: "collector_analysis_account")
    profile = account.instagram_profiles.create!(username: "collector_analysis_profile")

    post = profile.instagram_profile_posts.create!(
      instagram_account: account,
      shortcode: "analysis_1",
      caption: "old caption",
      permalink: "https://instagram.com/p/analysis_1/",
      source_media_url: "https://cdn.example.com/old.jpg",
      likes_count: 2,
      comments_count: 0,
      metadata: { "media_id" => "media_old", "media_type" => 1 },
      ai_status: "analyzed",
      analyzed_at: 2.hours.ago
    )

    dataset = {
      profile: {},
      posts: [
        {
          shortcode: "analysis_1",
          media_id: "media_new",
          media_type: 1,
          taken_at: Time.current,
          caption: "new caption",
          permalink: "https://instagram.com/p/analysis_1/",
          media_url: "https://cdn.example.com/new.jpg",
          image_url: nil,
          likes_count: 5,
          comments_count: 0,
          comments: []
        }
      ]
    }

    client_stub = Object.new
    client_stub.define_singleton_method(:fetch_profile_analysis_dataset!) { |**_kwargs| dataset }

    with_client_stub(client_stub) do
      collector = Instagram::ProfileAnalysisCollector.new(account: account, profile: profile)
      collector.define_singleton_method(:download_media) do |_url, **_kwargs|
        io = StringIO.new("new-media")
        [ io, "image/jpeg", "analysis_1.jpg" ]
      end

      result = collector.collect_and_persist!(
        posts_limit: nil,
        comments_limit: 8,
        track_missing_as_deleted: false,
        sync_source: "test_capture"
      )

      summary = result[:summary].is_a?(Hash) ? result[:summary] : {}
      assert_equal 1, summary[:updated_count].to_i
      assert_includes Array(summary[:updated_shortcodes]), "analysis_1"
      assert_includes Array(summary[:analysis_candidate_shortcodes]), "analysis_1"
    end

    post.reload
    assert_equal "pending", post.ai_status
    assert_nil post.analyzed_at
    assert_equal "media_new", post.metadata["media_id"]
  end

  private

  def with_client_stub(stubbed_client)
    singleton = class << Instagram::Client; self; end
    singleton.class_eval do
      alias_method :__collector_test_original_new, :new
      define_method(:new) { |**_kwargs| stubbed_client }
    end
    yield
  ensure
    singleton.class_eval do
      alias_method :new, :__collector_test_original_new
      remove_method :__collector_test_original_new
    end
  end
end
