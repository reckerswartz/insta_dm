require "set"

class SyncRecentProfilePostsForProfileJob < ApplicationJob
  class TransientProfileScanError < StandardError; end

  queue_as :post_downloads

  VISITED_TAG = "profile_posts_scanned".freeze
  ANALYZED_TAG = "profile_posts_analyzed".freeze
  MAX_POST_AGE_DAYS = 5
  PROFILE_SCAN_LOCK_NAMESPACE = 92_347

  retry_on Net::OpenTimeout, Net::ReadTimeout, wait: :polynomially_longer, attempts: 4
  retry_on Errno::ECONNREFUSED, Errno::ECONNRESET, wait: :polynomially_longer, attempts: 4
  retry_on Timeout::Error, wait: :polynomially_longer, attempts: 3
  retry_on TransientProfileScanError, wait: :polynomially_longer, attempts: 3
  selenium_timeout_error = "Selenium::WebDriver::Error::TimeoutError".safe_constantize
  retry_on selenium_timeout_error, wait: :polynomially_longer, attempts: 2 if selenium_timeout_error

  def perform(instagram_account_id:, instagram_profile_id:, posts_limit: 3, comments_limit: 8)
    account = InstagramAccount.find(instagram_account_id)
    profile = account.instagram_profiles.find(instagram_profile_id)
    posts_limit_i = posts_limit.to_i.clamp(1, 3)
    comments_limit_i = comments_limit.to_i.clamp(1, 20)
    lock_acquired = claim_profile_scan_lock!(profile_id: profile.id)
    unless lock_acquired
      Ops::StructuredLogger.info(
        event: "profile_scan.skipped_duplicate_execution",
        payload: {
          active_job_id: job_id,
          instagram_account_id: account.id,
          instagram_profile_id: profile.id
        }
      )
      return
    end

    action_log = profile.instagram_profile_action_logs.create!(
      instagram_account: account,
      action: "analyze_profile",
      status: "queued",
      trigger_source: "recurring_profile_recent_posts_scan",
      occurred_at: Time.current,
      active_job_id: job_id,
      queue_name: queue_name,
      metadata: { posts_limit: posts_limit_i, comments_limit: comments_limit_i }
    )
    action_log.mark_running!(extra_metadata: { active_job_id: job_id, queue_name: queue_name })

    story_result = fetch_story_dataset_with_fallback(account: account, profile: profile)
    story_dataset = story_result[:dataset]
    story_fetch_warning = story_result[:warning]
    update_story_activity!(profile: profile, story_dataset: story_dataset)
    policy_decision = Instagram::ProfileScanPolicy.new(profile: profile, profile_details: story_dataset[:profile]).decision
    if policy_decision[:skip_scan]
      handle_policy_skip!(
        account: account,
        profile: profile,
        action_log: action_log,
        decision: policy_decision,
        story_dataset: story_dataset,
        story_fetch_warning: story_fetch_warning
      )
      return
    end
    Instagram::ProfileScanPolicy.clear_scan_excluded!(profile: profile)

    existing_shortcodes = profile.instagram_profile_posts.pluck(:shortcode).to_set
    collected = Instagram::ProfileAnalysisCollector.new(account: account, profile: profile).collect_and_persist!(
      posts_limit: posts_limit_i,
      comments_limit: comments_limit_i
    )
    persisted_posts = Array(collected[:posts])
    feed_fetch = collected.dig(:summary, :feed_fetch)
    new_posts = persisted_posts.reject { |post| existing_shortcodes.include?(post.shortcode) }
    recent_cutoff = MAX_POST_AGE_DAYS.days.ago
    new_recent_posts = new_posts.select { |post| post.taken_at.present? && post.taken_at >= recent_cutoff }
    analysis_enqueue_failures = 0

    new_recent_posts.each do |post|
      post.update!(ai_status: "pending") if post.ai_status == "failed"
      AnalyzeInstagramProfilePostJob.perform_later(
        instagram_account_id: account.id,
        instagram_profile_id: profile.id,
        instagram_profile_post_id: post.id
      )
    rescue StandardError => enqueue_error
      analysis_enqueue_failures += 1
      Rails.logger.warn(
        "[SyncRecentProfilePostsForProfileJob] analyze enqueue failed for profile_post_id=#{post.id} " \
        "(profile_id=#{profile.id}): #{enqueue_error.class}: #{enqueue_error.message}"
      )
      next
    end

    apply_scan_tags!(profile: profile, has_new_posts: new_recent_posts.any?)
    profile.update!(last_synced_at: Time.current, ai_last_analyzed_at: Time.current)

    profile.record_event!(
      kind: "profile_recent_posts_scanned",
      external_id: "profile_recent_posts_scanned:#{Time.current.utc.iso8601(6)}",
      occurred_at: Time.current,
      metadata: {
        source: "recurring_profile_recent_posts_scan",
        stories_detected: Array(story_dataset[:stories]).length,
        latest_posts_fetched: persisted_posts.length,
        new_posts_enqueued_for_analysis: new_recent_posts.length,
        stale_posts_skipped_from_analysis: (new_posts.length - new_recent_posts.length),
        analysis_enqueue_failures: analysis_enqueue_failures,
        story_dataset_degraded: story_fetch_warning[:degraded],
        story_dataset_error_class: story_fetch_warning[:error_class],
        story_dataset_error_message: story_fetch_warning[:error_message]
      }
    )

    action_log.mark_succeeded!(
      extra_metadata: {
        stories_detected: Array(story_dataset[:stories]).length,
        fetched_posts: persisted_posts.length,
        new_posts: new_recent_posts.length,
        stale_posts_skipped_from_analysis: (new_posts.length - new_recent_posts.length),
        analysis_enqueue_failures: analysis_enqueue_failures,
        feed_fetch: feed_fetch.is_a?(Hash) ? feed_fetch : {},
        story_dataset_degraded: story_fetch_warning[:degraded],
        story_dataset_error_class: story_fetch_warning[:error_class],
        story_dataset_error_message: story_fetch_warning[:error_message]
      },
      log_text: "Scanned latest #{posts_limit_i} posts. New recent posts queued: #{new_recent_posts.length}, stale skipped: #{new_posts.length - new_recent_posts.length}, analysis enqueue failures: #{analysis_enqueue_failures}."
    )
  rescue StandardError => e
    normalized_error = normalize_job_error(e)
    action_log&.mark_failed!(
      error_message: normalized_error.message,
      extra_metadata: {
        active_job_id: job_id,
        executions: executions,
        error_class: normalized_error.class.name
      }
    )
    raise normalized_error
  ensure
    release_profile_scan_lock!(profile_id: profile.id) if lock_acquired
  end

  private

  def fetch_story_dataset_with_fallback(account:, profile:)
    dataset = Instagram::Client.new(account: account).fetch_profile_story_dataset!(
      username: profile.username,
      stories_limit: 3
    )
    {
      dataset: dataset,
      warning: { degraded: false, error_class: nil, error_message: nil }
    }
  rescue StandardError => e
    raise unless story_fetch_degradable_error?(e)

    Rails.logger.warn(
      "[SyncRecentProfilePostsForProfileJob] degraded story fetch for profile_id=#{profile.id} " \
      "(account_id=#{account.id}): #{e.class}: #{e.message}"
    )
    {
      dataset: {
        profile: {},
        user_id: nil,
        stories: [],
        fetched_at: Time.current
      },
      warning: {
        degraded: true,
        error_class: e.class.name,
        error_message: e.message.to_s
      }
    }
  end

  def story_fetch_degradable_error?(error)
    error.is_a?(Net::OpenTimeout) ||
      error.is_a?(Net::ReadTimeout) ||
      error.is_a?(Errno::ECONNREFUSED) ||
      error.is_a?(Errno::ECONNRESET) ||
      error.is_a?(Timeout::Error)
  end

  def normalize_job_error(error)
    authentication_error = normalize_authentication_error(error)
    return authentication_error if authentication_error

    normalize_retryable_error(error)
  end

  def normalize_authentication_error(error)
    return error if error.is_a?(Instagram::AuthenticationRequiredError)
    return nil unless error.is_a?(RuntimeError)

    message = error.message.to_s.downcase
    auth_runtime_message =
      message.include?("stored cookies are not authenticated") ||
      message.include?("authentication required") ||
      message.include?("no stored cookies")
    return nil unless auth_runtime_message

    wrapped = Instagram::AuthenticationRequiredError.new(error.message.to_s)
    wrapped.set_backtrace(error.backtrace)
    wrapped
  end

  def normalize_retryable_error(error)
    return error unless transient_runtime_error?(error)

    wrapped = TransientProfileScanError.new("Transient upstream response failure: #{error.message}")
    wrapped.set_backtrace(error.backtrace)
    wrapped
  end

  def transient_runtime_error?(error)
    return false unless error.is_a?(RuntimeError)

    message = error.message.to_s.downcase
    message.include?("http 429") ||
      message.include?("too many requests") ||
      message.include?("rate limit") ||
      message.include?("temporarily blocked")
  end

  def claim_profile_scan_lock!(profile_id:)
    return true unless postgres_adapter?

    key_a, key_b = profile_scan_lock_keys(profile_id: profile_id)
    value = ActiveRecord::Base.connection.select_value("SELECT pg_try_advisory_lock(#{key_a}, #{key_b})")
    ActiveModel::Type::Boolean.new.cast(value)
  rescue StandardError => e
    Rails.logger.warn("[SyncRecentProfilePostsForProfileJob] lock claim failed for profile_id=#{profile_id}: #{e.class}: #{e.message}")
    true
  end

  def release_profile_scan_lock!(profile_id:)
    return unless postgres_adapter?

    key_a, key_b = profile_scan_lock_keys(profile_id: profile_id)
    ActiveRecord::Base.connection.select_value("SELECT pg_advisory_unlock(#{key_a}, #{key_b})")
  rescue StandardError => e
    Rails.logger.warn("[SyncRecentProfilePostsForProfileJob] lock release failed for profile_id=#{profile_id}: #{e.class}: #{e.message}")
    nil
  end

  def profile_scan_lock_keys(profile_id:)
    [ PROFILE_SCAN_LOCK_NAMESPACE, profile_id.to_i ]
  end

  def postgres_adapter?
    ActiveRecord::Base.connection.adapter_name.to_s.downcase.include?("postgres")
  rescue StandardError
    false
  end

  def update_story_activity!(profile:, story_dataset:)
    stories = Array(story_dataset[:stories])
    details = story_dataset[:profile].is_a?(Hash) ? story_dataset[:profile] : {}

    profile.display_name = details[:display_name].presence || profile.display_name
    profile.profile_pic_url = details[:profile_pic_url].presence || profile.profile_pic_url
    profile.ig_user_id = details[:ig_user_id].presence || profile.ig_user_id
    profile.bio = details[:bio].presence || profile.bio
    profile.followers_count = normalize_count(details[:followers_count]) || profile.followers_count
    profile.last_post_at = details[:last_post_at].presence || profile.last_post_at

    if stories.any?
      latest_story_at = stories.filter_map { |story| story[:taken_at] }.compact.max || Time.current
      profile.last_story_seen_at = latest_story_at
      profile.record_event!(
        kind: "story_seen",
        external_id: "story_seen:profile_scan:#{profile.username}:#{latest_story_at.to_i}",
        occurred_at: latest_story_at,
        metadata: {
          source: "recurring_profile_recent_posts_scan",
          stories_detected: stories.length
        }
      )
    end

    profile.recompute_last_active!
    profile.save!
  end

  def normalize_count(value)
    text = value.to_s.strip
    return nil unless text.match?(/\A\d+\z/)

    text.to_i
  rescue StandardError
    nil
  end

  def handle_policy_skip!(account:, profile:, action_log:, decision:, story_dataset:, story_fetch_warning:)
    reason_code = decision[:reason_code].to_s
    if reason_code == "non_personal_profile_page" || reason_code == "scan_excluded_tag"
      Instagram::ProfileScanPolicy.mark_scan_excluded!(profile: profile)
    end

    profile.update!(last_synced_at: Time.current)
    profile.record_event!(
      kind: "profile_recent_posts_scan_skipped",
      external_id: "profile_recent_posts_scan_skipped:#{Time.current.utc.iso8601(6)}",
      occurred_at: Time.current,
      metadata: {
        source: "recurring_profile_recent_posts_scan",
        reason_code: reason_code,
        reason: decision[:reason],
        followers_count: decision[:followers_count],
        max_followers: decision[:max_followers],
        stories_detected: Array(story_dataset[:stories]).length,
        story_dataset_degraded: story_fetch_warning[:degraded],
        story_dataset_error_class: story_fetch_warning[:error_class],
        story_dataset_error_message: story_fetch_warning[:error_message]
      }
    )

    action_log.mark_succeeded!(
      extra_metadata: {
        skipped: true,
        skip_reason_code: reason_code,
        skip_reason: decision[:reason],
        followers_count: decision[:followers_count],
        max_followers: decision[:max_followers],
        stories_detected: Array(story_dataset[:stories]).length,
        story_dataset_degraded: story_fetch_warning[:degraded],
        story_dataset_error_class: story_fetch_warning[:error_class],
        story_dataset_error_message: story_fetch_warning[:error_message]
      },
      log_text: "Skipped profile scan: #{decision[:reason]}"
    )
  end

  def apply_scan_tags!(profile:, has_new_posts:)
    visited_tag = ProfileTag.find_or_create_by!(name: VISITED_TAG)
    profile.profile_tags << visited_tag unless profile.profile_tags.exists?(id: visited_tag.id)

    return unless has_new_posts

    analyzed_tag = ProfileTag.find_or_create_by!(name: ANALYZED_TAG)
    profile.profile_tags << analyzed_tag unless profile.profile_tags.exists?(id: analyzed_tag.id)
  end
end
