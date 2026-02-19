require "set"

class EnqueueRecentProfilePostScansForAccountJob < ApplicationJob
  queue_as :post_downloads

  VISITED_TAG = SyncRecentProfilePostsForProfileJob::VISITED_TAG
  ANALYZED_TAG = SyncRecentProfilePostsForProfileJob::ANALYZED_TAG
  PRIORITY_LEVELS = %i[high medium low].freeze
  PROFILE_SCAN_COOLDOWN_SECONDS = ENV.fetch("PROFILE_SCAN_COOLDOWN_SECONDS", "1800").to_i.clamp(60, 12.hours.to_i)
  PROFILE_SCAN_REFRESH_INTERVAL_SECONDS = ENV.fetch("PROFILE_SCAN_REFRESH_INTERVAL_SECONDS", "4500").to_i.clamp(300, 12.hours.to_i)
  PROFILE_SCAN_ACTIVE_LOOKBACK_SECONDS = ENV.fetch("PROFILE_SCAN_ACTIVE_LOOKBACK_SECONDS", "7200").to_i.clamp(300, 24.hours.to_i)
  PROFILE_SCAN_INSPECTION_MULTIPLIER = ENV.fetch("PROFILE_SCAN_INSPECTION_MULTIPLIER", "8").to_i.clamp(2, 20)
  PROFILE_SCAN_MAX_INSPECTION = ENV.fetch("PROFILE_SCAN_MAX_INSPECTION", "320").to_i.clamp(30, 2000)

  def perform(instagram_account_id:, limit_per_account: 8, posts_limit: 3, comments_limit: 8)
    account = InstagramAccount.find(instagram_account_id)
    return if account.cookies.blank?
    now = Time.current

    cap = limit_per_account.to_i.clamp(1, 30)
    posts_limit_i = posts_limit.to_i.clamp(1, 3)
    comments_limit_i = comments_limit.to_i.clamp(1, 20)

    selection = pick_profiles_for_scan(account: account, limit: cap, now: now)
    active_scans = active_profile_scan_profile_ids(
      account: account,
      profile_ids: selection[:candidate_profile_ids],
      now: now
    )
    enqueued = 0
    considered_profile_id = nil
    skipped = []

    selection[:ordered_candidates].each do |candidate|
      break if enqueued >= cap

      profile = candidate[:profile]
      priority = candidate[:priority].to_s
      considered_profile_id = profile.id
      skip_reason = skip_reason_for_profile_scan(profile: profile, active_scans: active_scans, now: now)
      if skip_reason.present?
        skipped << { profile_id: profile.id, priority: priority, reason: skip_reason }
        next
      end

      SyncRecentProfilePostsForProfileJob.perform_later(
        instagram_account_id: account.id,
        instagram_profile_id: profile.id,
        posts_limit: posts_limit_i,
        comments_limit: comments_limit_i
      )
      enqueued += 1
    rescue StandardError => e
      skipped << { profile_id: profile&.id, priority: priority, reason: "enqueue_failed", error_class: e.class.name }
      Ops::StructuredLogger.warn(
        event: "profile_scan.enqueue_failed",
        payload: {
          account_id: account.id,
          profile_id: profile.id,
          error_class: e.class.name,
          error_message: e.message
        }
      )
    end

    persist_scheduler_cursor!(
      account: account,
      cursor_id: considered_profile_id || selection[:cursor_end_id],
      now: now
    )

    Ops::StructuredLogger.info(
      event: "profile_scan.account_batch_enqueued",
      payload: {
        account_id: account.id,
        candidate_profiles: selection[:candidate_profile_ids].length,
        selected_profiles: selection[:ordered_candidates].length,
        enqueued_jobs: enqueued,
        skipped_profiles: skipped.length,
        skipped_reasons: skipped.group_by { |row| row[:reason] }.transform_values(&:length),
        cursor_start_id: selection[:cursor_start_id],
        cursor_end_id: considered_profile_id || selection[:cursor_end_id],
        priority_counts: selection[:priority_counts],
        limit_per_account: cap,
        posts_limit: posts_limit_i,
        comments_limit: comments_limit_i,
        profile_scan_cooldown_seconds: PROFILE_SCAN_COOLDOWN_SECONDS,
        scan_refresh_interval_seconds: PROFILE_SCAN_REFRESH_INTERVAL_SECONDS
      }
    )
  rescue StandardError => e
    Ops::StructuredLogger.error(
      event: "profile_scan.account_batch_failed",
      payload: {
        account_id: instagram_account_id,
        error_class: e.class.name,
        error_message: e.message
      }
    )
    raise
  end

  private

  def pick_profiles_for_scan(account:, limit:, now:)
    candidate_ids = account.instagram_profiles
      .where("following = ? OR follows_you = ?", true, true)
      .order(:id)
      .pluck(:id)

    if candidate_ids.empty?
      return {
        candidate_profile_ids: [],
        ordered_candidates: [],
        cursor_start_id: account.continuous_processing_profile_scan_cursor_id,
        cursor_end_id: account.continuous_processing_profile_scan_cursor_id,
        priority_counts: {}
      }
    end

    cursor_start_id = account.continuous_processing_profile_scan_cursor_id
    rotated_ids = rotate_ids(ids: candidate_ids, cursor_id: cursor_start_id)
    inspection_count = [ [ limit * PROFILE_SCAN_INSPECTION_MULTIPLIER, limit ].max, PROFILE_SCAN_MAX_INSPECTION, rotated_ids.length ].min
    inspection_ids = rotated_ids.first(inspection_count)
    profile_by_id = account.instagram_profiles
      .where(id: inspection_ids)
      .includes(:profile_tags)
      .to_a
      .index_by(&:id)
    inspected_profiles = inspection_ids.filter_map { |id| profile_by_id[id] }
    eligible_profiles = inspected_profiles.reject { |profile| Instagram::ProfileScanPolicy.skip_from_cached_profile?(profile: profile) }
    weighted = eligible_profiles.map { |profile| { profile: profile, priority: scan_priority_for(profile: profile, now: now) } }
    ordered_candidates = PRIORITY_LEVELS.flat_map do |priority|
      weighted.select { |row| row[:priority] == priority }
    end

    {
      candidate_profile_ids: eligible_profiles.map(&:id),
      ordered_candidates: ordered_candidates,
      cursor_start_id: cursor_start_id,
      cursor_end_id: inspection_ids.last,
      priority_counts: weighted.group_by { |row| row[:priority] }.transform_values(&:size)
    }
  end

  def skip_reason_for_profile_scan(profile:, active_scans:, now:)
    return "already_queued_or_running" if active_scans.include?(profile.id)

    last_scan_at = profile.ai_last_analyzed_at || profile.last_synced_at
    return nil if last_scan_at.blank?
    return nil if last_scan_at <= (now - PROFILE_SCAN_COOLDOWN_SECONDS.seconds)

    last_activity_at = [ profile.last_post_at, profile.last_story_seen_at ].compact.max
    return nil if last_activity_at.present? && last_activity_at > last_scan_at

    "cooldown_active"
  end

  def scan_priority_for(profile:, now:)
    last_scan_at = profile.ai_last_analyzed_at || profile.last_synced_at
    last_activity_at = [ profile.last_post_at, profile.last_story_seen_at ].compact.max
    tag_names = profile.profile_tags.map { |tag| tag.name.to_s }
    unseen = !tag_names.include?(VISITED_TAG) || !tag_names.include?(ANALYZED_TAG)

    return :high if last_scan_at.blank?
    return :high if unseen
    return :high if last_activity_at.present? && last_activity_at > last_scan_at
    return :medium if last_scan_at <= (now - PROFILE_SCAN_REFRESH_INTERVAL_SECONDS.seconds)

    :low
  end

  def active_profile_scan_profile_ids(account:, profile_ids:, now:)
    return Set.new if profile_ids.empty?

    lookback = now - PROFILE_SCAN_ACTIVE_LOOKBACK_SECONDS.seconds
    ids = account.instagram_profile_action_logs
      .where(action: "analyze_profile", status: %w[queued running], instagram_profile_id: profile_ids)
      .where("occurred_at >= ?", lookback)
      .distinct
      .pluck(:instagram_profile_id)

    ids.to_set
  end

  def rotate_ids(ids:, cursor_id:)
    return ids if ids.empty? || cursor_id.blank?

    index = ids.index(cursor_id.to_i)
    return ids unless index

    ids.drop(index + 1) + ids.take(index + 1)
  end

  def persist_scheduler_cursor!(account:, cursor_id:, now:)
    updates = {
      continuous_processing_last_profile_scan_enqueued_at: now,
      updated_at: Time.current
    }
    updates[:continuous_processing_profile_scan_cursor_id] = cursor_id.to_i if cursor_id.present?
    account.update_columns(updates)
  rescue StandardError
    nil
  end
end
