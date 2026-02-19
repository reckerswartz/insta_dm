require "rails_helper"
require "securerandom"

RSpec.describe "EnqueueRecentProfilePostScansForAccountJobTest" do
  it "filters out excluded/high-follower profiles before enqueueing scan jobs" do
    account = InstagramAccount.create!(
      username: "acct_#{SecureRandom.hex(4)}",
      cookies_json: [{ name: "sessionid", value: "ok" }].to_json
    )

    allowed = account.instagram_profiles.create!(username: "allowed_#{SecureRandom.hex(2)}", followers_count: 900, following: true)
    high_follower = account.instagram_profiles.create!(username: "popular_#{SecureRandom.hex(2)}", followers_count: 60_000, following: true)
    excluded = account.instagram_profiles.create!(username: "excluded_#{SecureRandom.hex(2)}", followers_count: 500, following: true)
    excluded_tag = ProfileTag.find_or_create_by!(name: Instagram::ProfileScanPolicy::EXCLUDED_SCAN_TAG)
    excluded.profile_tags << excluded_tag

    enqueued_profile_ids = []
    with_scan_enqueue_capture(enqueued_profile_ids) do
      EnqueueRecentProfilePostScansForAccountJob.perform_now(
        instagram_account_id: account.id,
        limit_per_account: 5,
        posts_limit: 3,
        comments_limit: 8
      )
    end

    assert_equal [allowed.id], enqueued_profile_ids
    assert_not_includes enqueued_profile_ids, high_follower.id
    assert_not_includes enqueued_profile_ids, excluded.id
  end

  private

  def with_scan_enqueue_capture(profile_ids)
    singleton = class << SyncRecentProfilePostsForProfileJob; self; end
    singleton.class_eval do
      alias_method :__scan_enqueue_test_original_perform_later, :perform_later
      define_method(:perform_later) do |**kwargs|
        profile_ids << kwargs[:instagram_profile_id]
        Struct.new(:job_id, :queue_name).new("test_job_id", "profiles")
      end
    end
    yield
  ensure
    singleton.class_eval do
      alias_method :perform_later, :__scan_enqueue_test_original_perform_later
      remove_method :__scan_enqueue_test_original_perform_later
    end
  end
end
