require "stringio"
require "net/http"

class CaptureInstagramProfilePostsJob < ApplicationJob
  queue_as :post_downloads

  DOWNLOAD_TARGET_RECENT_POSTS = 50
  CAPTURE_FETCH_LIMIT = 120

  retry_on Net::OpenTimeout, Net::ReadTimeout, wait: :polynomially_longer, attempts: 4
  retry_on Errno::ECONNRESET, Errno::ECONNREFUSED, wait: :polynomially_longer, attempts: 4
  retry_on Timeout::Error, wait: :polynomially_longer, attempts: 3

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
      posts_limit: CAPTURE_FETCH_LIMIT,
      comments_limit: comments_limit_i,
      track_missing_as_deleted: true,
      sync_source: "profile_posts_manual_capture",
      download_media: false
    )

    persisted_posts = Array(collected[:posts])
    summary = collected[:summary].is_a?(Hash) ? collected[:summary] : {}
    created_shortcodes = Array(summary[:created_shortcodes])
    updated_shortcodes = Array(summary[:updated_shortcodes])
    restored_shortcodes = Array(summary[:restored_shortcodes])
    deleted_shortcodes = Array(summary[:deleted_shortcodes])

    event_counts = create_post_capture_events!(
      profile: profile,
      posts: persisted_posts,
      created_shortcodes: created_shortcodes,
      restored_shortcodes: restored_shortcodes,
      deleted_shortcodes: deleted_shortcodes
    )

    download_plan = build_download_plan(profile: profile)
    queued_downloads = enqueue_profile_post_downloads!(
      account: account,
      profile: profile,
      posts: download_plan[:to_queue]
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
        recent_download_target: DOWNLOAD_TARGET_RECENT_POSTS,
        recent_downloadable_posts: download_plan[:recent_candidates].length,
        recent_already_downloaded: download_plan[:already_downloaded_count],
        recent_missing_downloads: download_plan[:missing_count],
        queued_download_jobs: queued_downloads[:queued_count],
        queue_failures: queued_downloads[:failures].length,
        captured_events_count: event_counts[:captured],
        deleted_events_count: event_counts[:deleted],
        restored_events_count: event_counts[:restored],
        downloadable_manifest_count: download_plan[:manifest].length
      }
    )

    Turbo::StreamsChannel.broadcast_append_to(
      account,
      target: "notifications",
      partial: "shared/notification",
      locals: {
        kind: "notice",
        message: "Post capture completed for #{profile.username}. New: #{summary[:created_count].to_i}, restored: #{summary[:restored_count].to_i}, deleted flagged: #{summary[:deleted_count].to_i}, queued downloads: #{queued_downloads[:queued_count]}, already downloaded in recent set: #{download_plan[:already_downloaded_count]}/#{DOWNLOAD_TARGET_RECENT_POSTS}."
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
        recent_download_target: DOWNLOAD_TARGET_RECENT_POSTS,
        recent_downloadable_posts: download_plan[:recent_candidates].length,
        recent_already_downloaded: download_plan[:already_downloaded_count],
        recent_missing_downloads: download_plan[:missing_count],
        queued_download_jobs: queued_downloads[:queued_count],
        queued_download_post_ids: queued_downloads[:post_ids].first(DOWNLOAD_TARGET_RECENT_POSTS),
        queue_failures: queued_downloads[:failures].first(20),
        download_manifest: download_plan[:manifest].first(DOWNLOAD_TARGET_RECENT_POSTS),
        captured_events_count: event_counts[:captured]
      },
      log_text: "Captured posts (new=#{summary[:created_count].to_i}, restored=#{summary[:restored_count].to_i}, updated=#{summary[:updated_count].to_i}, deleted=#{summary[:deleted_count].to_i}, queued_downloads=#{queued_downloads[:queued_count]}, already_downloaded_recent=#{download_plan[:already_downloaded_count]})."
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

  def build_download_plan(profile:)
    recent_candidates = profile.instagram_profile_posts
      .with_attached_media
      .recent_first
      .limit(CAPTURE_FETCH_LIMIT)
      .select { |post| downloadable_profile_post?(post) }
      .first(DOWNLOAD_TARGET_RECENT_POSTS)

    already_downloaded_count = recent_candidates.count { |post| post.media.attached? }
    missing_posts = recent_candidates.reject { |post| post.media.attached? }
    required = [DOWNLOAD_TARGET_RECENT_POSTS - already_downloaded_count, 0].max
    to_queue = missing_posts.first(required)

    manifest = recent_candidates.map do |post|
      metadata = post.metadata.is_a?(Hash) ? post.metadata : {}
      {
        post_id: post.id,
        shortcode: post.shortcode,
        post_kind: metadata["post_kind"].to_s.presence || "post",
        product_type: metadata["product_type"].to_s.presence,
        repost: ActiveModel::Type::Boolean.new.cast(metadata["is_repost"]),
        media_type: metadata["media_type"],
        media_id: metadata["media_id"],
        media_url: post.source_media_url.to_s.presence || metadata["media_url_video"].to_s.presence || metadata["media_url_image"].to_s.presence,
        taken_at: post.taken_at&.iso8601,
        downloaded: post.media.attached?
      }.compact
    end

    {
      recent_candidates: recent_candidates,
      already_downloaded_count: already_downloaded_count,
      missing_count: missing_posts.length,
      to_queue: to_queue,
      manifest: manifest
    }
  end

  def enqueue_profile_post_downloads!(account:, profile:, posts:)
    post_ids = []
    failures = []

    Array(posts).each do |post|
      next unless post
      next unless downloadable_profile_post?(post)

      mark_download_queued!(post: post)
      job = DownloadInstagramProfilePostMediaJob.perform_later(
        instagram_account_id: account.id,
        instagram_profile_id: profile.id,
        instagram_profile_post_id: post.id,
        trigger_analysis: true
      )
      post_ids << post.id
      profile.record_event!(
        kind: "profile_post_media_download_queued",
        external_id: "profile_post_media_download_queued:#{post.id}:#{job.job_id}",
        occurred_at: Time.current,
        metadata: {
          source: self.class.name,
          instagram_profile_post_id: post.id,
          shortcode: post.shortcode,
          active_job_id: job.job_id
        }
      )
    rescue StandardError => e
      failures << {
        instagram_profile_post_id: post&.id,
        shortcode: post&.shortcode.to_s.presence,
        error_class: e.class.name,
        error_message: e.message.to_s.byteslice(0, 220)
      }.compact
      next
    end

    {
      queued_count: post_ids.length,
      post_ids: post_ids,
      failures: failures
    }
  end

  def downloadable_profile_post?(post)
    return false unless post
    return false if ActiveModel::Type::Boolean.new.cast(post.metadata.is_a?(Hash) ? post.metadata["deleted_from_source"] : nil)

    source_url = post.source_media_url.to_s.strip
    return true if source_url.present?

    metadata = post.metadata.is_a?(Hash) ? post.metadata : {}
    metadata["media_url_video"].to_s.strip.present? || metadata["media_url_image"].to_s.strip.present?
  end

  def mark_download_queued!(post:)
    metadata = post.metadata.is_a?(Hash) ? post.metadata.deep_dup : {}
    post.update!(
      metadata: metadata.merge(
        "download_status" => "queued",
        "download_queued_at" => Time.current.utc.iso8601(3),
        "download_queued_by" => self.class.name,
        "download_error" => nil
      )
    )
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
