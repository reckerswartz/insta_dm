require "set"

class SyncRecentProfilePostsForProfileJob < ApplicationJob
  queue_as :profiles

  VISITED_TAG = "profile_posts_scanned".freeze
  ANALYZED_TAG = "profile_posts_analyzed".freeze
  MAX_POST_AGE_DAYS = 5

  def perform(instagram_account_id:, instagram_profile_id:, posts_limit: 3, comments_limit: 8)
    account = InstagramAccount.find(instagram_account_id)
    profile = account.instagram_profiles.find(instagram_profile_id)
    posts_limit_i = posts_limit.to_i.clamp(1, 3)
    comments_limit_i = comments_limit.to_i.clamp(1, 20)

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

    story_dataset = Instagram::Client.new(account: account).fetch_profile_story_dataset!(
      username: profile.username,
      stories_limit: 3
    )
    update_story_activity!(profile: profile, story_dataset: story_dataset)

    existing_shortcodes = profile.instagram_profile_posts.pluck(:shortcode).to_set
    collected = Instagram::ProfileAnalysisCollector.new(account: account, profile: profile).collect_and_persist!(
      posts_limit: posts_limit_i,
      comments_limit: comments_limit_i
    )
    persisted_posts = Array(collected[:posts])
    new_posts = persisted_posts.reject { |post| existing_shortcodes.include?(post.shortcode) }
    recent_cutoff = MAX_POST_AGE_DAYS.days.ago
    new_recent_posts = new_posts.select { |post| post.taken_at.present? && post.taken_at >= recent_cutoff }

    new_recent_posts.each do |post|
      post.update!(ai_status: "pending") if post.ai_status == "failed"
      AnalyzeInstagramProfilePostJob.perform_later(
        instagram_account_id: account.id,
        instagram_profile_id: profile.id,
        instagram_profile_post_id: post.id
      )
    rescue StandardError
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
        stale_posts_skipped_from_analysis: (new_posts.length - new_recent_posts.length)
      }
    )

    action_log.mark_succeeded!(
      extra_metadata: {
        stories_detected: Array(story_dataset[:stories]).length,
        fetched_posts: persisted_posts.length,
        new_posts: new_recent_posts.length,
        stale_posts_skipped_from_analysis: (new_posts.length - new_recent_posts.length)
      },
      log_text: "Scanned latest #{posts_limit_i} posts. New recent posts queued: #{new_recent_posts.length}, stale skipped: #{new_posts.length - new_recent_posts.length}."
    )
  rescue StandardError => e
    action_log&.mark_failed!(error_message: e.message, extra_metadata: { active_job_id: job_id })
    raise
  end

  private

  def update_story_activity!(profile:, story_dataset:)
    stories = Array(story_dataset[:stories])
    details = story_dataset[:profile].is_a?(Hash) ? story_dataset[:profile] : {}

    profile.display_name = details[:display_name].presence || profile.display_name
    profile.profile_pic_url = details[:profile_pic_url].presence || profile.profile_pic_url
    profile.ig_user_id = details[:ig_user_id].presence || profile.ig_user_id
    profile.bio = details[:bio].presence || profile.bio
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

  def apply_scan_tags!(profile:, has_new_posts:)
    visited_tag = ProfileTag.find_or_create_by!(name: VISITED_TAG)
    profile.profile_tags << visited_tag unless profile.profile_tags.exists?(id: visited_tag.id)

    return unless has_new_posts

    analyzed_tag = ProfileTag.find_or_create_by!(name: ANALYZED_TAG)
    profile.profile_tags << analyzed_tag unless profile.profile_tags.exists?(id: analyzed_tag.id)
  end
end
