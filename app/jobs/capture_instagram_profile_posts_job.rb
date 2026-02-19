require "stringio"

class CaptureInstagramProfilePostsJob < ApplicationJob
  queue_as :profiles

  def perform(instagram_account_id:, instagram_profile_id:, profile_action_log_id: nil, comments_limit: 20)
    account = InstagramAccount.find(instagram_account_id)
    profile = account.instagram_profiles.find(instagram_profile_id)
    comments_limit_i = comments_limit.to_i.clamp(1, 30)
    action_log = find_or_create_action_log(
      account: account,
      profile: profile,
      profile_action_log_id: profile_action_log_id
    )
    action_log.mark_running!(extra_metadata: {
      queue_name: queue_name,
      active_job_id: job_id,
      comments_limit: comments_limit_i
    })

    Ops::StructuredLogger.info(
      event: "profile_posts_capture.started",
      payload: {
        active_job_id: job_id,
        instagram_account_id: account.id,
        instagram_profile_id: profile.id,
        profile_username: profile.username,
        comments_limit: comments_limit_i
      }
    )

    policy_decision = Instagram::ProfileScanPolicy.new(profile: profile).decision
    if policy_decision[:skip_scan]
      if policy_decision[:reason_code].to_s == "non_personal_profile_page" || policy_decision[:reason_code].to_s == "scan_excluded_tag"
        Instagram::ProfileScanPolicy.mark_scan_excluded!(profile: profile)
      end

      action_log.mark_succeeded!(
        extra_metadata: {
          skipped: true,
          skip_reason_code: policy_decision[:reason_code],
          skip_reason: policy_decision[:reason],
          followers_count: policy_decision[:followers_count],
          max_followers: policy_decision[:max_followers]
        },
        log_text: "Skipped profile post capture: #{policy_decision[:reason]}"
      )
      return
    end

    collected = Instagram::ProfileAnalysisCollector.new(account: account, profile: profile).collect_and_persist!(
      posts_limit: 100,
      comments_limit: comments_limit_i,
      track_missing_as_deleted: true,
      sync_source: "profile_posts_manual_capture"
    )

    persisted_posts = Array(collected[:posts])
    summary = collected[:summary].is_a?(Hash) ? collected[:summary] : {}
    created_shortcodes = Array(summary[:created_shortcodes])
    updated_shortcodes = Array(summary[:updated_shortcodes])
    restored_shortcodes = Array(summary[:restored_shortcodes])
    deleted_shortcodes = Array(summary[:deleted_shortcodes])
    analysis_candidate_shortcodes = Array(summary[:analysis_candidate_shortcodes])

    event_counts = create_post_capture_events!(
      profile: profile,
      posts: persisted_posts,
      created_shortcodes: created_shortcodes,
      restored_shortcodes: restored_shortcodes,
      deleted_shortcodes: deleted_shortcodes
    )
    analysis_enqueue = enqueue_post_analysis_followup!(
      account: account,
      profile: profile,
      persisted_posts: persisted_posts,
      analysis_candidate_shortcodes: analysis_candidate_shortcodes
    )

    profile.update!(last_synced_at: Time.current)

    Ops::StructuredLogger.info(
      event: "profile_posts_capture.completed",
      payload: {
        active_job_id: job_id,
        instagram_account_id: account.id,
        instagram_profile_id: profile.id,
        profile_username: profile.username,
        fetched_posts: persisted_posts.length,
        created_count: summary[:created_count].to_i,
        restored_count: summary[:restored_count].to_i,
        updated_count: summary[:updated_count].to_i,
        unchanged_count: summary[:unchanged_count].to_i,
        deleted_count: summary[:deleted_count].to_i,
        analysis_candidates_count: analysis_enqueue[:candidate_count],
        total_analysis_candidates: analysis_enqueue[:total_candidates_count],
        analysis_job_queued: analysis_enqueue[:queued],
        captured_events_count: event_counts[:captured],
        deleted_events_count: event_counts[:deleted],
        restored_events_count: event_counts[:restored]
      }
    )

    Turbo::StreamsChannel.broadcast_append_to(
      account,
      target: "notifications",
      partial: "shared/notification",
      locals: {
        kind: "notice",
        message: "Post capture completed for #{profile.username}. New: #{summary[:created_count].to_i}, restored: #{summary[:restored_count].to_i}, deleted flagged: #{summary[:deleted_count].to_i}, queued for analysis: #{analysis_enqueue[:candidate_count]}."
      }
    )

    action_log.mark_succeeded!(
      extra_metadata: {
        fetched_posts: persisted_posts.length,
        created_count: summary[:created_count].to_i,
        restored_count: summary[:restored_count].to_i,
        updated_count: summary[:updated_count].to_i,
        unchanged_count: summary[:unchanged_count].to_i,
        deleted_count: summary[:deleted_count].to_i,
        feed_fetch: summary[:feed_fetch].is_a?(Hash) ? summary[:feed_fetch] : {},
        created_shortcodes: created_shortcodes.first(40),
        updated_shortcodes: updated_shortcodes.first(40),
        restored_shortcodes: restored_shortcodes.first(40),
        deleted_shortcodes: deleted_shortcodes.first(40),
        analysis_candidate_shortcodes: analysis_candidate_shortcodes.first(120),
        analysis_candidates_count: analysis_enqueue[:candidate_count],
        total_analysis_candidates: analysis_enqueue[:total_candidates_count],
        analysis_job_queued: analysis_enqueue[:queued],
        analysis_job_id: analysis_enqueue[:job_id],
        analysis_action_log_id: analysis_enqueue[:action_log_id],
        captured_events_count: event_counts[:captured]
      },
      log_text: "Captured posts (new=#{summary[:created_count].to_i}, restored=#{summary[:restored_count].to_i}, updated=#{summary[:updated_count].to_i}, deleted=#{summary[:deleted_count].to_i}, queued_for_analysis=#{analysis_enqueue[:candidate_count]})."
    )
  rescue StandardError => e
    Ops::StructuredLogger.error(
      event: "profile_posts_capture.failed",
      payload: {
        active_job_id: job_id,
        instagram_account_id: account&.id,
        instagram_profile_id: profile&.id,
        error_class: e.class.name,
        error_message: e.message.to_s
      }
    )
    Turbo::StreamsChannel.broadcast_append_to(
      account,
      target: "notifications",
      partial: "shared/notification",
      locals: { kind: "alert", message: "Profile post capture failed: #{e.message}" }
    ) if account
    action_log&.mark_failed!(error_message: e.message, extra_metadata: { active_job_id: job_id })
    raise
  end

  private

  def find_or_create_action_log(account:, profile:, profile_action_log_id:)
    log = profile.instagram_profile_action_logs.find_by(id: profile_action_log_id) if profile_action_log_id.present?
    return log if log

    profile.instagram_profile_action_logs.create!(
      instagram_account: account,
      action: "capture_profile_posts",
      status: "queued",
      trigger_source: "job",
      occurred_at: Time.current,
      active_job_id: job_id,
      queue_name: queue_name,
      metadata: { created_by: self.class.name }
    )
  end

  def create_post_capture_events!(profile:, posts:, created_shortcodes:, restored_shortcodes:, deleted_shortcodes:)
    by_shortcode = posts.index_by { |post| post.shortcode.to_s }
    counts = { captured: 0, deleted: 0, restored: 0 }

    created_shortcodes.each do |shortcode|
      post = by_shortcode[shortcode.to_s] || profile.instagram_profile_posts.find_by(shortcode: shortcode.to_s)
      next unless post

      event = profile.record_event!(
        kind: "profile_post_captured",
        external_id: "profile_post_captured:#{post.shortcode}",
        occurred_at: post.taken_at || Time.current,
        metadata: profile_post_event_metadata(post: post, reason: "new_capture")
      )
      attach_post_media_to_event(event: event, post: post)
      counts[:captured] += 1
    end

    restored_shortcodes.each do |shortcode|
      post = by_shortcode[shortcode.to_s] || profile.instagram_profile_posts.find_by(shortcode: shortcode.to_s)
      next unless post

      profile.record_event!(
        kind: "profile_post_restored",
        external_id: "profile_post_restored:#{post.shortcode}:#{Time.current.utc.iso8601(6)}",
        occurred_at: Time.current,
        metadata: profile_post_event_metadata(post: post, reason: "restored_in_capture")
      )
      counts[:restored] += 1
    end

    deleted_shortcodes.each do |shortcode|
      post = profile.instagram_profile_posts.find_by(shortcode: shortcode.to_s)
      profile.record_event!(
        kind: "profile_post_deleted_detected",
        external_id: "profile_post_deleted_detected:#{shortcode}:#{Time.current.utc.iso8601(6)}",
        occurred_at: Time.current,
        metadata: {
          source: "profile_posts_manual_capture",
          shortcode: shortcode,
          instagram_profile_post_id: post&.id,
          deleted_from_source: true,
          preserved_in_history: true
        }
      )
      counts[:deleted] += 1
    end

    counts
  end

  def enqueue_post_analysis_followup!(account:, profile:, persisted_posts:, analysis_candidate_shortcodes:)
    candidates = resolve_analysis_candidates(
      profile: profile,
      persisted_posts: persisted_posts,
      analysis_candidate_shortcodes: analysis_candidate_shortcodes
    )
    return { queued: false, candidate_count: 0, job_id: nil, action_log_id: nil } if candidates.empty?

    # Limit to first 50 posts for initial analysis
    limited_candidates = candidates.first(50)

    analysis_log = profile.instagram_profile_action_logs.create!(
      instagram_account: account,
      action: "analyze_profile_posts",
      status: "queued",
      trigger_source: "job",
      occurred_at: Time.current,
      metadata: {
        requested_by: self.class.name,
        queued_post_ids: limited_candidates,
        queued_post_count: limited_candidates.length,
        total_candidates_count: candidates.length,
        analysis_batch: "initial_50"
      }
    )

    job = AnalyzeCapturedInstagramProfilePostsJob.perform_later(
      instagram_account_id: account.id,
      instagram_profile_id: profile.id,
      profile_action_log_id: analysis_log.id,
      post_ids: limited_candidates,
      refresh_profile_insights: true
    )
    analysis_log.update!(active_job_id: job.job_id, queue_name: job.queue_name)

    {
      queued: true,
      candidate_count: limited_candidates.length,
      total_candidates_count: candidates.length,
      job_id: job.job_id,
      action_log_id: analysis_log.id
    }
  rescue StandardError => e
    Rails.logger.warn("[CaptureInstagramProfilePostsJob] unable to queue post-analysis followup: #{e.class}: #{e.message}")
    { queued: false, candidate_count: candidates&.length.to_i, job_id: nil, action_log_id: nil }
  end

  def resolve_analysis_candidates(profile:, persisted_posts:, analysis_candidate_shortcodes:)
    shortcodes = Array(analysis_candidate_shortcodes).map(&:to_s).map(&:strip).reject(&:blank?).uniq
    return [] if shortcodes.empty?

    by_shortcode = Array(persisted_posts).index_by { |post| post.shortcode.to_s }
    ids = shortcodes.filter_map do |shortcode|
      post = by_shortcode[shortcode] || profile.instagram_profile_posts.find_by(shortcode: shortcode)
      next unless post
      next if ActiveModel::Type::Boolean.new.cast(post.metadata.is_a?(Hash) ? post.metadata["deleted_from_source"] : nil)

      post.id
    end
    ids.uniq
  end

  def profile_post_event_metadata(post:, reason:)
    metadata = post.metadata.is_a?(Hash) ? post.metadata : {}
    {
      source: "profile_posts_manual_capture",
      shortcode: post.shortcode,
      reason: reason.to_s,
      instagram_profile_post_id: post.id,
      permalink: post.permalink_url,
      likes_count: post.likes_count,
      comments_count: post.comments_count,
      media_type: metadata["media_type"],
      media_id: metadata["media_id"],
      deleted_from_source: false
    }
  end

  def attach_post_media_to_event(event:, post:)
    return unless event
    return unless post.media.attached?
    return if event.media.attached?

    blob = post.media.blob
    event.media.attach(
      io: StringIO.new(blob.download),
      filename: blob.filename.to_s,
      content_type: blob.content_type
    )
  rescue StandardError => e
    Rails.logger.warn("[CaptureInstagramProfilePostsJob] unable to attach post media to event #{event&.id}: #{e.class}: #{e.message}")
  end
end
