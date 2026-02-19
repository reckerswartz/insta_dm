require "rails_helper"
require "securerandom"

RSpec.describe "SyncRecentProfilePostsForProfileJobTest" do
  include ActiveJob::TestHelper

  before do
    clear_enqueued_jobs
    clear_performed_jobs
  end

  it "retries on transient collector timeout failures" do
    account = InstagramAccount.create!(username: "acct_retry_#{SecureRandom.hex(3)}")
    profile = account.instagram_profiles.create!(username: "profile_retry_#{SecureRandom.hex(3)}")

    client_stub = Object.new
    client_stub.define_singleton_method(:fetch_profile_story_dataset!) do |**_kwargs|
      { profile: {}, user_id: nil, stories: [], fetched_at: Time.current }
    end

    collector_stub = Object.new
    collector_stub.define_singleton_method(:collect_and_persist!) do |**_kwargs|
      raise Net::ReadTimeout, "profile analysis timed out"
    end

    with_client_stub(client_stub) do
      with_collector_stub(collector_stub) do
        assert_enqueued_with(job: SyncRecentProfilePostsForProfileJob) do
          SyncRecentProfilePostsForProfileJob.perform_now(
            instagram_account_id: account.id,
            instagram_profile_id: profile.id,
            posts_limit: 3,
            comments_limit: 8
          )
        end
      end
    end

    action_log = profile.instagram_profile_action_logs.where(action: "analyze_profile").order(id: :desc).first
    assert_not_nil action_log
    assert_equal "failed", action_log.status
    assert_equal "Net::ReadTimeout", action_log.metadata["error_class"]
  end

  it "retries when upstream returns a rate-limit runtime error" do
    account = InstagramAccount.create!(username: "acct_rate_#{SecureRandom.hex(3)}")
    profile = account.instagram_profiles.create!(username: "profile_rate_#{SecureRandom.hex(3)}")

    client_stub = Object.new
    client_stub.define_singleton_method(:fetch_profile_story_dataset!) do |**_kwargs|
      { profile: {}, user_id: nil, stories: [], fetched_at: Time.current }
    end

    collector_stub = Object.new
    collector_stub.define_singleton_method(:collect_and_persist!) do |**_kwargs|
      raise RuntimeError, "HTTP 429 Too Many Requests"
    end

    with_client_stub(client_stub) do
      with_collector_stub(collector_stub) do
        assert_enqueued_with(job: SyncRecentProfilePostsForProfileJob) do
          SyncRecentProfilePostsForProfileJob.perform_now(
            instagram_account_id: account.id,
            instagram_profile_id: profile.id,
            posts_limit: 3,
            comments_limit: 8
          )
        end
      end
    end

    action_log = profile.instagram_profile_action_logs.where(action: "analyze_profile").order(id: :desc).first
    assert_not_nil action_log
    assert_equal "failed", action_log.status
    assert_equal "SyncRecentProfilePostsForProfileJob::TransientProfileScanError", action_log.metadata["error_class"]
  end

  it "maps authentication runtime errors to AuthenticationRequired and avoids retry enqueue" do
    account = InstagramAccount.create!(username: "acct_auth_#{SecureRandom.hex(3)}")
    profile = account.instagram_profiles.create!(username: "profile_auth_#{SecureRandom.hex(3)}")

    client_stub = Object.new
    client_stub.define_singleton_method(:fetch_profile_story_dataset!) do |**_kwargs|
      { profile: {}, user_id: nil, stories: [], fetched_at: Time.current }
    end

    collector_stub = Object.new
    collector_stub.define_singleton_method(:collect_and_persist!) do |**_kwargs|
      raise RuntimeError, "Stored cookies are not authenticated. Re-run Manual Browser Login or import fresh cookies."
    end

    with_client_stub(client_stub) do
      with_collector_stub(collector_stub) do
        assert_no_enqueued_jobs only: SyncRecentProfilePostsForProfileJob do
          SyncRecentProfilePostsForProfileJob.perform_now(
            instagram_account_id: account.id,
            instagram_profile_id: profile.id,
            posts_limit: 3,
            comments_limit: 8
          )
        end
      end
    end

    action_log = profile.instagram_profile_action_logs.where(action: "analyze_profile").order(id: :desc).first
    assert_not_nil action_log
    assert_equal "failed", action_log.status
    assert_equal "Instagram::AuthenticationRequiredError", action_log.metadata["error_class"]
  end

  it "skips duplicate execution when profile scan lock is not available" do
    account = InstagramAccount.create!(username: "acct_lock_#{SecureRandom.hex(3)}")
    profile = account.instagram_profiles.create!(username: "profile_lock_#{SecureRandom.hex(3)}")

    allow_any_instance_of(SyncRecentProfilePostsForProfileJob).to receive(:claim_profile_scan_lock!).and_return(false)

    SyncRecentProfilePostsForProfileJob.perform_now(
      instagram_account_id: account.id,
      instagram_profile_id: profile.id,
      posts_limit: 3,
      comments_limit: 8
    )

    assert_equal 0, profile.instagram_profile_action_logs.where(action: "analyze_profile").count
  end

  it "degrades story fetch timeout and still completes profile post sync" do
    account = InstagramAccount.create!(username: "acct_degrade_#{SecureRandom.hex(3)}")
    profile = account.instagram_profiles.create!(username: "profile_degrade_#{SecureRandom.hex(3)}")

    client_stub = Object.new
    client_stub.define_singleton_method(:fetch_profile_story_dataset!) do |**_kwargs|
      raise Net::ReadTimeout, "stories timed out"
    end

    collector_called = false
    collector_stub = Object.new
    collector_stub.define_singleton_method(:collect_and_persist!) do |**_kwargs|
      collector_called = true
      { posts: [], summary: { feed_fetch: { source: "http_feed_api", pages_fetched: 0 } } }
    end

    with_client_stub(client_stub) do
      with_collector_stub(collector_stub) do
        SyncRecentProfilePostsForProfileJob.perform_now(
          instagram_account_id: account.id,
          instagram_profile_id: profile.id,
          posts_limit: 3,
          comments_limit: 8
        )
      end
    end

    action_log = profile.instagram_profile_action_logs.where(action: "analyze_profile").order(id: :desc).first
    assert_not_nil action_log
    assert_equal "succeeded", action_log.status
    assert_equal true, ActiveModel::Type::Boolean.new.cast(action_log.metadata["story_dataset_degraded"])
    assert_equal "Net::ReadTimeout", action_log.metadata["story_dataset_error_class"]
    assert_equal true, collector_called
    assert_not_nil profile.reload.last_synced_at
  end

  private

  def with_client_stub(stubbed_client)
    singleton = class << Instagram::Client; self; end
    singleton.class_eval do
      alias_method :__sync_recent_posts_test_original_new, :new
      define_method(:new) { |**_kwargs| stubbed_client }
    end
    yield
  ensure
    singleton.class_eval do
      alias_method :new, :__sync_recent_posts_test_original_new
      remove_method :__sync_recent_posts_test_original_new
    end
  end

  def with_collector_stub(stubbed_collector)
    singleton = class << Instagram::ProfileAnalysisCollector; self; end
    singleton.class_eval do
      alias_method :__sync_recent_posts_test_original_new, :new
      define_method(:new) { |**_kwargs| stubbed_collector }
    end
    yield
  ensure
    singleton.class_eval do
      alias_method :new, :__sync_recent_posts_test_original_new
      remove_method :__sync_recent_posts_test_original_new
    end
  end
end
