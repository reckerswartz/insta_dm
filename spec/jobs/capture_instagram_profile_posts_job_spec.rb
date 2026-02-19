require "rails_helper"
require "securerandom"

RSpec.describe "CaptureInstagramProfilePostsJobTest" do
  include ActiveJob::TestHelper
  before do
    clear_enqueued_jobs
    clear_performed_jobs
  end
  it "capture job builds download manifest and queues profile post media downloads" do
    account = InstagramAccount.create!(username: "acct_#{SecureRandom.hex(4)}")
    profile = account.instagram_profiles.create!(username: "profile_#{SecureRandom.hex(4)}")
    post = profile.instagram_profile_posts.create!(
      instagram_account: account,
      shortcode: "post_a1",
      caption: "new",
      permalink: "https://instagram.com/p/post_a1/",
      source_media_url: "https://cdn.example.com/a1.jpg",
      metadata: { "media_id" => "m1", "media_type" => 1 },
      likes_count: 1,
      comments_count: 0
    )

    collector_stub = Struct.new(:result) do
      attr_reader :captured_kwargs

      def collect_and_persist!(**kwargs)
        @captured_kwargs = kwargs
        result
      end
    end.new(
      {
        posts: [post],
        summary: {
          created_count: 1,
          restored_count: 0,
          updated_count: 0,
          unchanged_count: 0,
          deleted_count: 0,
          created_shortcodes: ["post_a1"],
          restored_shortcodes: [],
          updated_shortcodes: [],
          deleted_shortcodes: [],
          feed_fetch: { "source" => "http_feed_api", "pages_fetched" => 1 }
        }
      }
    )

    with_profile_collector_stub(collector_stub) do
      assert_enqueued_with(job: DownloadInstagramProfilePostMediaJob) do
        CaptureInstagramProfilePostsJob.perform_now(
          instagram_account_id: account.id,
          instagram_profile_id: profile.id,
          comments_limit: 12
        )
      end
    end

    assert_equal false, ActiveModel::Type::Boolean.new.cast(collector_stub.captured_kwargs[:download_media])
    capture_log = profile.instagram_profile_action_logs.where(action: "capture_profile_posts").order(id: :desc).first
    assert_not_nil capture_log
    assert_equal "succeeded", capture_log.status
    assert_equal 50, capture_log.metadata["recent_download_target"].to_i
    assert_equal 1, capture_log.metadata["queued_download_jobs"].to_i
    assert_equal 1, Array(capture_log.metadata["download_manifest"]).length
  end
  it "capture job skips scan when profile exceeds followers threshold" do
    account = InstagramAccount.create!(username: "acct_#{SecureRandom.hex(4)}")
    profile = account.instagram_profiles.create!(
      username: "profile_#{SecureRandom.hex(4)}",
      followers_count: 45_000
    )

    collector_stub = Object.new
    collector_stub.define_singleton_method(:collect_and_persist!) do |**_kwargs|
      raise "collector should not run for high-follower profiles"
    end

    with_profile_collector_stub(collector_stub) do
      assert_no_enqueued_jobs only: DownloadInstagramProfilePostMediaJob do
        CaptureInstagramProfilePostsJob.perform_now(
          instagram_account_id: account.id,
          instagram_profile_id: profile.id,
          comments_limit: 12
        )
      end
    end

    capture_log = profile.instagram_profile_action_logs.where(action: "capture_profile_posts").order(id: :desc).first
    assert_not_nil capture_log
    assert_equal "succeeded", capture_log.status
    assert_equal true, ActiveModel::Type::Boolean.new.cast(capture_log.metadata["skipped"])
    assert_equal "followers_threshold_exceeded", capture_log.metadata["skip_reason_code"]
  end

  private

  def with_profile_collector_stub(stubbed_collector)
    singleton = class << Instagram::ProfileAnalysisCollector; self; end
    singleton.class_eval do
      alias_method :__capture_posts_test_original_new, :new
      define_method(:new) { |**_kwargs| stubbed_collector }
    end
    yield
  ensure
    singleton.class_eval do
      alias_method :new, :__capture_posts_test_original_new
      remove_method :__capture_posts_test_original_new
    end
  end
end
