require "net/http"
require "digest"
require "stringio"
require "timeout"

class SyncInstagramProfileStoriesJob < ApplicationJob
  queue_as :story_processing

  MAX_STORIES = 10
  MEDIA_DOWNLOAD_ATTEMPTS = 3

  retry_on Net::OpenTimeout, Net::ReadTimeout, wait: :polynomially_longer, attempts: 3
  retry_on Errno::ECONNRESET, Errno::ECONNREFUSED, wait: :polynomially_longer, attempts: 3
  retry_on Timeout::Error, wait: :polynomially_longer, attempts: 2

  def perform(instagram_account_id:, instagram_profile_id:, profile_action_log_id: nil, max_stories: MAX_STORIES, force_analyze_all: false, auto_reply: false, require_auto_reply_tag: false)
    account = InstagramAccount.find(instagram_account_id)
    profile = account.instagram_profiles.find(instagram_profile_id)
    max_stories_i = max_stories.to_i.clamp(1, 10)
    force = ActiveModel::Type::Boolean.new.cast(force_analyze_all)
    auto_reply_enabled = ActiveModel::Type::Boolean.new.cast(auto_reply)
    action_log = find_or_create_action_log(
      account: account,
      profile: profile,
      action: auto_reply_enabled ? "auto_story_reply" : "sync_stories",
      profile_action_log_id: profile_action_log_id
    )
    tagged_for_auto_reply = automatic_reply_enabled?(profile)
    if require_auto_reply_tag && !tagged_for_auto_reply
      action_log.mark_succeeded!(log_text: "Skipped: automatic_reply tag not present", extra_metadata: { skipped: true, reason: "missing_automatic_reply_tag" })
      return
    end
    action_log.mark_running!(extra_metadata: {
      queue_name: queue_name,
      active_job_id: job_id,
      max_stories: max_stories_i,
      force_analyze_all: force,
      auto_reply: auto_reply_enabled
    })
    Ops::StructuredLogger.info(
      event: "profile_story_sync.started",
      payload: {
        active_job_id: job_id,
        instagram_account_id: account.id,
        instagram_profile_id: profile.id,
        profile_username: profile.username,
        max_stories: max_stories_i,
        force_analyze_all: force,
        auto_reply: auto_reply_enabled
      }
    )

    dataset = Instagram::Client.new(account: account).fetch_profile_story_dataset!(
      username: profile.username,
      stories_limit: max_stories_i
    )

    sync_profile_snapshot!(profile: profile, details: dataset[:profile] || {})

    stories = Array(dataset[:stories]).first(max_stories_i)
    downloaded_count = 0
    reused_download_count = 0
    analysis_queued_count = 0
    story_failures = []

    stories.each do |story|
      story_id = story[:story_id].to_s
      next if story_id.blank?

      # Capture HTML snapshot for debugging story skipping
      capture_story_html_snapshot(profile: profile, story: story, story_index: stories.find_index(story))

      if story[:api_should_skip]
        profile.record_event!(
          kind: "story_skipped_debug",
          external_id: "story_skipped_debug:#{story_id}:#{Time.current.utc.iso8601(6)}",
          occurred_at: Time.current,
          metadata: base_story_metadata(profile: profile, story: story).merge(
            skip_reason: story[:api_external_profile_reason].to_s.presence || "api_external_profile_indicator",
            skip_source: "api_story_item_attribution",
            skip_targets: Array(story[:api_external_profile_targets]),
            duplicate_download_prevented: latest_story_download_event(profile: profile, story_id: story_id).present?
          )
        )
        skipped_download = download_skipped_story!(
          account: account,
          profile: profile,
          story: story,
          skip_reason: story[:api_external_profile_reason].to_s.presence || "api_external_profile_indicator"
        )
        downloaded_count += 1 if skipped_download[:downloaded]
        reused_download_count += 1 if skipped_download[:reused]
        next
      end

      already_processed = already_processed_story?(profile: profile, story_id: story_id)
      if already_processed && !force
        dedupe = dedupe_state_for_story(profile: profile, story_id: story_id)
        profile.record_event!(
          kind: "story_skipped_debug",
          external_id: "story_skipped_debug:#{story_id}:#{Time.current.utc.iso8601(6)}",
          occurred_at: Time.current,
          metadata: base_story_metadata(profile: profile, story: story).merge(
            skip_reason: "already_processed",
            skip_category: "duplicate",
            force_analyze_all: force,
            story_index: stories.find_index(story),
            total_stories: stories.size,
            duplicate_download_prevented: latest_story_download_event(profile: profile, story_id: story_id).present?,
            dedupe_state: dedupe
          )
        )
        next
      end

      upload_event = profile.record_event!(
        kind: "story_uploaded",
        external_id: "story_uploaded:#{story_id}",
        occurred_at: story[:taken_at],
        metadata: base_story_metadata(profile: profile, story: story)
      )

      viewed_at = Time.current
      profile.update!(last_story_seen_at: viewed_at)
      profile.recompute_last_active!
      profile.save!

      profile.record_event!(
        kind: "story_viewed",
        external_id: "story_viewed:#{story_id}:#{viewed_at.utc.iso8601(6)}",
        occurred_at: viewed_at,
        metadata: base_story_metadata(profile: profile, story: story).merge(viewed_at: viewed_at.iso8601)
      )

      media_url = story[:media_url].to_s.strip
      if media_url.blank?
        profile.record_event!(
          kind: "story_skipped_debug",
          external_id: "story_skipped_debug:#{story_id}:#{Time.current.utc.iso8601(6)}",
          occurred_at: Time.current,
          metadata: base_story_metadata(profile: profile, story: story).merge(
            skip_reason: "missing_media_url",
            skip_category: "media_missing",
            story_index: stories.find_index(story),
            total_stories: stories.size
          )
        )
        next
      end

      existing_download_event = latest_story_download_event(profile: profile, story_id: story_id)
      reused_media = load_existing_story_media(event: existing_download_event)
      reused_media ||= load_existing_story_media_from_ingested_story(profile: profile, story_id: story_id)
      reused_media ||= load_cached_story_media_for_profile(
        account: account,
        profile: profile,
        story: story
      )
      if reused_media
        bytes = reused_media[:bytes]
        content_type = reused_media[:content_type]
        filename = reused_media[:filename]
        downloaded_event = reused_media[:event]
        if downloaded_event.blank?
          downloaded_at = Time.current
          downloaded_event = profile.record_event!(
            kind: "story_downloaded",
            external_id: story_download_external_id(story_id),
            occurred_at: downloaded_at,
            metadata: base_story_metadata(profile: profile, story: story).merge(
              downloaded_at: downloaded_at.iso8601,
              media_filename: filename,
              media_content_type: content_type,
              media_bytes: bytes.bytesize,
              reused_local_cache: true,
              reused_local_cache_source: "instagram_story_same_profile"
            )
          )
          if reused_media[:blob].present?
            attach_blob_to_event(downloaded_event, blob: reused_media[:blob])
          else
            attach_media_to_event(downloaded_event, bytes: bytes, filename: filename, content_type: content_type)
          end
        end
        reused_download_count += 1
      else
        bytes, content_type, filename = download_story_media_with_retry(url: media_url, user_agent: account.user_agent)
        downloaded_at = Time.current
        downloaded_event = profile.record_event!(
          kind: "story_downloaded",
          external_id: story_download_external_id(story_id),
          occurred_at: downloaded_at,
          metadata: base_story_metadata(profile: profile, story: story).merge(
            downloaded_at: downloaded_at.iso8601,
            media_filename: filename,
            media_content_type: content_type,
            media_bytes: bytes.bytesize
          )
        )

        attach_media_to_event(downloaded_event, bytes: bytes, filename: filename, content_type: content_type)
        InstagramProfileEvent.broadcast_story_archive_refresh!(account: account)
        downloaded_count += 1
      end

      attach_media_to_event(upload_event, bytes: bytes, filename: filename, content_type: content_type)
      enqueue_story_preview_generation!(
        event: downloaded_event,
        story: story,
        user_agent: account.user_agent
      )
      ingested_story = ingest_story_for_processing(
        account: account,
        profile: profile,
        story: story,
        downloaded_event: downloaded_event,
        bytes: bytes,
        content_type: content_type,
        filename: filename,
        force_reprocess: force
      )

      queued = enqueue_story_analysis!(
        account: account,
        profile: profile,
        story: story,
        downloaded_event: downloaded_event,
        ingested_story: ingested_story,
        auto_reply: auto_reply_enabled
      )
      analysis_queued_count += 1 if queued
    rescue StandardError => e
      failure = classify_story_failure(error: e).merge(
        error_class: e.class.name,
        error_message: e.message.to_s.byteslice(0, 500)
      )
      record_story_sync_failed_event(
        profile: profile,
        story: story,
        story_id: story_id,
        failure: failure
      )
      story_failures << {
        story_id: story_id.presence || story[:story_id].to_s,
        reason: failure[:reason],
        category: failure[:category],
        retryable: failure[:retryable],
        error_class: e.class.name,
        error_message: e.message.to_s.byteslice(0, 220)
      }
      Ops::StructuredLogger.warn(
        event: "profile_story_sync.story_failed",
        payload: {
          active_job_id: job_id,
          instagram_account_id: account.id,
          instagram_profile_id: profile.id,
          profile_username: profile.username,
          story_id: story_id.presence || story[:story_id].to_s,
          error_class: e.class.name,
          error_message: e.message.to_s
        }
      )
      next
    end

    Ops::StructuredLogger.info(
      event: "profile_story_sync.completed",
      payload: {
        active_job_id: job_id,
        instagram_account_id: account.id,
        instagram_profile_id: profile.id,
        profile_username: profile.username,
        stories_found: stories.size,
        downloaded: downloaded_count,
        reused_downloads: reused_download_count,
        analysis_jobs_queued: analysis_queued_count,
        failed_story_count: story_failures.length,
        failed_by_category: story_failures.each_with_object(Hash.new(0)) { |row, memo| memo[row[:category].to_s] += 1 },
        failed_retryable_count: story_failures.count { |row| row[:retryable] == true },
        skip_by_reason: summarize_skip_reasons(profile: profile, stories: stories)
      }
    )

    Turbo::StreamsChannel.broadcast_append_to(
      account,
      target: "notifications",
      partial: "shared/notification",
      locals: { kind: "notice", message: "Story sync completed for #{profile.username}. Stories: #{stories.size}, downloaded: #{downloaded_count}, reused: #{reused_download_count}, analysis jobs queued: #{analysis_queued_count}, failed: #{story_failures.length}." }
    )

    action_log.mark_succeeded!(
      extra_metadata: {
        stories_found: stories.size,
        downloaded: downloaded_count,
        reused_downloads: reused_download_count,
        analysis_jobs_queued: analysis_queued_count,
        failed_story_count: story_failures.length,
        failed_stories: story_failures.first(15)
      },
      log_text: "Synced #{stories.size} stories (downloaded: #{downloaded_count}, reused: #{reused_download_count}, analysis jobs queued: #{analysis_queued_count}, failed: #{story_failures.length})"
    )
  rescue StandardError => e
    Ops::StructuredLogger.error(
      event: "profile_story_sync.failed",
      payload: {
        active_job_id: job_id,
        instagram_account_id: account&.id,
        instagram_profile_id: profile&.id,
        profile_username: profile&.username,
        error_class: e.class.name,
        error_message: e.message.to_s
      }
    )
    Turbo::StreamsChannel.broadcast_append_to(
      account,
      target: "notifications",
      partial: "shared/notification",
      locals: { kind: "alert", message: "Story sync failed: #{e.message}" }
    ) if account
    action_log&.mark_failed!(error_message: e.message, extra_metadata: { active_job_id: job_id })
    raise
  end

  private

  def find_or_create_action_log(account:, profile:, action:, profile_action_log_id:)
    log = profile.instagram_profile_action_logs.find_by(id: profile_action_log_id) if profile_action_log_id.present?
    return log if log

    profile.instagram_profile_action_logs.create!(
      instagram_account: account,
      action: action,
      status: "queued",
      trigger_source: "job",
      occurred_at: Time.current,
      active_job_id: job_id,
      queue_name: queue_name,
      metadata: { created_by: self.class.name }
    )
  end

  def sync_profile_snapshot!(profile:, details:)
    profile.update!(
      display_name: details[:display_name].presence || profile.display_name,
      profile_pic_url: details[:profile_pic_url].presence || profile.profile_pic_url,
      ig_user_id: details[:ig_user_id].presence || profile.ig_user_id,
      bio: details[:bio].presence || profile.bio,
      last_post_at: details[:last_post_at].presence || profile.last_post_at
    )
    profile.recompute_last_active!
    profile.save!
  end

  def base_story_metadata(profile:, story:)
    {
      source: "instagram_story_reel_api",
      story_id: story[:story_id],
      media_type: story[:media_type],
      media_url: story[:media_url],
      image_url: story[:image_url],
      video_url: story[:video_url],
      primary_media_source: story[:primary_media_source],
      primary_media_index: story[:primary_media_index],
      media_variants_count: Array(story[:media_variants]).length,
      carousel_media: compact_story_media_variants(story[:carousel_media]),
      can_reply: story[:can_reply],
      can_reshare: story[:can_reshare],
      owner_user_id: story[:owner_user_id],
      owner_username: story[:owner_username],
      api_has_external_profile_indicator: story[:api_has_external_profile_indicator],
      api_external_profile_reason: story[:api_external_profile_reason],
      api_external_profile_targets: story[:api_external_profile_targets],
      api_should_skip: story[:api_should_skip],
      caption: story[:caption],
      permalink: story[:permalink],
      upload_time: story[:taken_at]&.iso8601,
      expiring_at: story[:expiring_at]&.iso8601,
      profile_context: {
        username: profile.username,
        display_name: profile.display_name,
        can_message: profile.can_message,
        tags: profile.profile_tags.pluck(:name).sort,
        bio: profile.bio.to_s.tr("\n", " ").byteslice(0, 260)
      }
    }
  end

  def compact_story_media_variants(variants)
    Array(variants).first(8).filter_map do |entry|
      data = entry.is_a?(Hash) ? entry : {}
      media_url = data[:media_url] || data["media_url"]
      next nil if media_url.to_s.blank?

      {
        source: (data[:source] || data["source"]).to_s.presence,
        index: data[:index] || data["index"],
        media_pk: (data[:media_pk] || data["media_pk"]).to_s.presence,
        media_type: (data[:media_type] || data["media_type"]).to_s.presence,
        media_url: media_url.to_s,
        image_url: (data[:image_url] || data["image_url"]).to_s.presence,
        video_url: (data[:video_url] || data["video_url"]).to_s.presence,
        width: data[:width] || data["width"],
        height: data[:height] || data["height"]
      }.compact
    end
  rescue StandardError
    []
  end

  def automatic_reply_enabled?(profile)
    profile.profile_tags.where(name: [ "automatic_reply", "automatic reply" ]).exists?
  end

  def already_processed_story?(profile:, story_id:)
    state = dedupe_state_for_story(profile: profile, story_id: story_id)
    state[:downloaded_with_media] || state[:analyzed] || state[:replied]
  end

  def dedupe_state_for_story(profile:, story_id:)
    sid = story_id.to_s.strip
    return { downloaded_with_media: false, analyzed: false, replied: false, uploaded_only: false } if sid.blank?

    latest_download = latest_story_download_event(profile: profile, story_id: sid)
    downloaded_with_media = latest_download&.media&.attached? == true
    analyzed = profile.instagram_profile_events
      .where(kind: "story_analyzed")
      .where("metadata ->> 'story_id' = ?", sid)
      .exists?
    replied = profile.instagram_profile_events
      .where(kind: "story_reply_sent", external_id: "story_reply_sent:#{sid}")
      .exists?
    uploaded = profile.instagram_profile_events
      .where(kind: "story_uploaded", external_id: "story_uploaded:#{sid}")
      .exists?

    {
      downloaded_with_media: downloaded_with_media,
      analyzed: analyzed,
      replied: replied,
      uploaded_only: uploaded && !downloaded_with_media && !analyzed && !replied
    }
  rescue StandardError
    { downloaded_with_media: false, analyzed: false, replied: false, uploaded_only: false }
  end

  def attach_media_to_event(event, bytes:, filename:, content_type:)
    return unless event
    return if event.media.attached?

    event.media.attach(io: StringIO.new(bytes), filename: filename, content_type: content_type)
  rescue StandardError
    nil
  end

  def enqueue_story_preview_generation!(event:, story:, user_agent:)
    return false unless event&.media&.attached?
    return false unless event.media.blob&.content_type.to_s.start_with?("video/")
    return false if event.preview_image.attached?

    job = GenerateStoryPreviewImageJob.perform_later(
      instagram_profile_event_id: event.id,
      story_payload: story_payload_for_job(story: story),
      user_agent: user_agent.to_s
    )

    metadata = event.metadata.is_a?(Hash) ? event.metadata.deep_dup : {}
    metadata["preview_image_status"] = "queued"
    metadata["preview_image_source"] = "story_preview_generation_job"
    metadata["preview_image_queued_at"] = Time.current.utc.iso8601(3)
    metadata["preview_image_job_id"] = job.job_id
    metadata["preview_image_queue_name"] = job.queue_name
    event.update!(metadata: metadata)

    true
  rescue StandardError => e
    Rails.logger.warn("[SyncInstagramProfileStoriesJob] preview enqueue failed event_id=#{event&.id}: #{e.class}: #{e.message}")
    false
  end

  def story_analysis_already_queued?(profile:, story_id:)
    event = profile.instagram_profile_events.find_by(kind: "story_analysis_queued", external_id: "story_analysis_queued:#{story_id}")
    return false unless event

    metadata = event.metadata.is_a?(Hash) ? event.metadata : {}
    status = metadata["status"].to_s
    return false if %w[completed failed].include?(status)

    event.detected_at.present? && event.detected_at > 12.hours.ago
  rescue StandardError
    false
  end

  def enqueue_story_analysis!(account:, profile:, story:, downloaded_event:, ingested_story:, auto_reply:)
    story_id = story[:story_id].to_s.strip
    return false if story_id.blank? || downloaded_event.blank?
    return false if story_analysis_already_queued?(profile: profile, story_id: story_id)

    queue_event = profile.record_event!(
      kind: "story_analysis_queued",
      external_id: "story_analysis_queued:#{story_id}",
      occurred_at: Time.current,
      metadata: base_story_metadata(profile: profile, story: story).merge(
        status: "queued",
        queued_at: Time.current.iso8601(3),
        auto_reply: ActiveModel::Type::Boolean.new.cast(auto_reply),
        downloaded_event_id: downloaded_event.id,
        instagram_story_id: ingested_story&.id
      )
    )

    job = AnalyzeInstagramStoryEventJob.perform_later(
      instagram_account_id: account.id,
      instagram_profile_id: profile.id,
      story_id: story_id,
      story_payload: story_payload_for_job(story: story),
      downloaded_event_id: downloaded_event.id,
      ingested_story_id: ingested_story&.id,
      auto_reply: auto_reply
    )

    queue_event.update!(
      metadata: queue_event.metadata.merge(
        "active_job_id" => job.job_id,
        "queue_name" => job.queue_name
      )
    )

    true
  rescue StandardError => e
    return false if e.is_a?(ActiveRecord::RecordNotUnique)

    Rails.logger.warn("[SyncInstagramProfileStoriesJob] story analysis enqueue failed story_id=#{story_id}: #{e.class}: #{e.message}")
    false
  end

  def story_payload_for_job(story:)
    payload = story.is_a?(Hash) ? story.deep_dup : {}
    normalized = payload.deep_stringify_keys
    %w[taken_at expiring_at].each do |key|
      value = normalized[key]
      normalized[key] = value.iso8601 if value.respond_to?(:iso8601)
    end
    normalized
  rescue StandardError
    {}
  end

  def download_skipped_story!(account:, profile:, story:, skip_reason:)
    story_id = story[:story_id].to_s
    existing_event = latest_story_download_event(profile: profile, story_id: story_id)
    if existing_event&.media&.attached?
      return { downloaded: false, reused: true, event: existing_event }
    end
    reused_media = load_cached_story_media_for_profile(
      account: account,
      profile: profile,
      story: story,
      skip_reason: skip_reason
    )
    return { downloaded: false, reused: true, event: reused_media[:event] } if reused_media

    media_url = story[:media_url].to_s.strip
    return { downloaded: false, reused: false, event: nil } if media_url.blank?

    bytes, content_type, filename = download_story_media_with_retry(url: media_url, user_agent: account.user_agent)
    downloaded_at = Time.current
    event = profile.record_event!(
      kind: "story_downloaded",
      external_id: story_download_external_id(story_id),
      occurred_at: downloaded_at,
      metadata: base_story_metadata(profile: profile, story: story).merge(
        skipped: true,
        skip_reason: skip_reason.to_s,
        downloaded_at: downloaded_at.iso8601,
        media_filename: filename,
        media_content_type: content_type,
        media_bytes: bytes.bytesize
      )
    )
    attach_media_to_event(event, bytes: bytes, filename: filename, content_type: content_type)
    InstagramProfileEvent.broadcast_story_archive_refresh!(account: account)
    { downloaded: true, reused: false, event: event }
  rescue StandardError
    { downloaded: false, reused: false, event: nil }
  end

  def summarize_skip_reasons(profile:, stories:)
    story_ids = Array(stories).filter_map { |s| s.is_a?(Hash) ? s[:story_id].to_s.presence : nil }
    return {} if story_ids.empty?

    profile.instagram_profile_events
      .where(kind: "story_skipped_debug")
      .where("metadata ->> 'story_id' IN (?)", story_ids)
      .where("detected_at >= ?", 1.hour.ago)
      .limit(500)
      .each_with_object(Hash.new(0)) do |event, memo|
        metadata = event.metadata.is_a?(Hash) ? event.metadata : {}
        reason = metadata["skip_reason"].to_s.presence || "unknown"
        memo[reason] += 1
      end
  rescue StandardError
    {}
  end

  def classify_story_failure(error:)
    klass = error.class.name.to_s
    message = error.message.to_s
    normalized = message.downcase

    if transient_failure?(error: error, normalized: normalized)
      return {
        reason: "transient_network_error",
        category: "network",
        retryable: true,
        resolution: "Retry automatically with backoff."
      }
    end
    if session_failure?(normalized: normalized)
      return {
        reason: "session_or_cookie_invalid",
        category: "session",
        retryable: false,
        resolution: "Refresh login/session cookies for this account."
      }
    end
    if media_failure?(normalized: normalized)
      return {
        reason: "media_download_or_validation_failed",
        category: "media_fetch",
        retryable: normalized.include?("http 5") || normalized.include?("http 429"),
        resolution: "Inspect story media URL/headers and retry if source recovers."
      }
    end

    {
      reason: "#{klass.underscore}_failure",
      category: "unknown",
      retryable: false,
      resolution: "Inspect stack trace and metadata for root cause."
    }
  end

  def record_story_sync_failed_event(profile:, story:, story_id:, failure:)
    profile.record_event!(
      kind: "story_sync_failed",
      external_id: "story_sync_failed:#{story_id}:#{Time.current.utc.iso8601(6)}",
      occurred_at: Time.current,
      metadata: base_story_metadata(profile: profile, story: story).merge(
        reason: failure[:reason],
        failure_category: failure[:category],
        retryable: failure[:retryable],
        resolution_hint: failure[:resolution],
        error_class: failure[:error_class] || nil,
        error_message: failure[:error_message] || nil
      ).compact
    )
  rescue StandardError
    nil
  end

  def transient_failure?(error:, normalized:)
    return true if error.is_a?(Net::OpenTimeout) || error.is_a?(Net::ReadTimeout)
    return true if error.is_a?(Errno::ECONNRESET) || error.is_a?(Errno::ECONNREFUSED)
    return true if error.is_a?(Timeout::Error)

    normalized.include?("timeout") ||
      normalized.include?("temporarily unavailable") ||
      normalized.include?("connection reset") ||
      normalized.include?("read timeout") ||
      normalized.include?("open timeout") ||
      normalized.include?("http 502") ||
      normalized.include?("http 503") ||
      normalized.include?("http 504") ||
      normalized.include?("http 429")
  end

  def session_failure?(normalized:)
    normalized.include?("session expired") ||
      normalized.include?("not authenticated") ||
      normalized.include?("login") ||
      normalized.include?("cookie") ||
      normalized.include?("csrf") ||
      normalized.include?("checkpoint")
  end

  def media_failure?(normalized:)
    normalized.include?("invalid media url") ||
      normalized.include?("empty story media body") ||
      normalized.include?("invalid video signature") ||
      normalized.include?("invalid jpeg signature") ||
      normalized.include?("invalid png signature") ||
      normalized.include?("invalid webp signature") ||
      normalized.include?("http")
  end

  def download_story_media_with_retry(url:, user_agent:)
    attempt = 0
    begin
      attempt += 1
      download_story_media(url: url, user_agent: user_agent)
    rescue StandardError => e
      raise unless transient_failure?(error: e, normalized: e.message.to_s.downcase)
      raise if attempt >= MEDIA_DOWNLOAD_ATTEMPTS

      sleep(0.4 * attempt)
      retry
    end
  end

  def download_story_media(url:, user_agent:)
    uri = URI.parse(url)
    raise "Invalid story media URL" unless uri.is_a?(URI::HTTP) || uri.is_a?(URI::HTTPS)

    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = (uri.scheme == "https")
    http.open_timeout = 10
    http.read_timeout = 30

    req = Net::HTTP::Get.new(uri.request_uri)
    req["User-Agent"] = user_agent.presence || "Mozilla/5.0"
    req["Accept"] = "*/*"
    req["Referer"] = "https://www.instagram.com/"

    res = http.request(req)

    if res.is_a?(Net::HTTPRedirection) && res["location"].present?
      return download_story_media(url: res["location"], user_agent: user_agent)
    end

    raise "HTTP #{res.code}" unless res.is_a?(Net::HTTPSuccess)

    bytes = res.body.to_s
    raise "Empty story media body" if bytes.blank?

    content_type = res["content-type"].to_s.split(";").first.presence || "application/octet-stream"
    ext = extension_for_content_type(content_type: content_type)
    digest = Digest::SHA256.hexdigest("#{uri.path}-#{bytes.bytesize}")[0, 12]
    filename = "story_#{digest}.#{ext}"

    [ bytes, content_type, filename ]
  end

  def extension_for_content_type(content_type:)
    return "jpg" if content_type.include?("jpeg")
    return "png" if content_type.include?("png")
    return "webp" if content_type.include?("webp")
    return "mp4" if content_type.include?("mp4")
    return "mov" if content_type.include?("quicktime")

    "bin"
  end

  def ingest_story_for_processing(account:, profile:, story:, downloaded_event:, bytes:, content_type:, filename:, force_reprocess:)
    StoryIngestionService.new(account: account, profile: profile).ingest!(
      story: story,
      source_event: downloaded_event,
      bytes: bytes,
      content_type: content_type,
      filename: filename,
      force_reprocess: force_reprocess
    )
  rescue StandardError => e
    Rails.logger.warn("[SyncInstagramProfileStoriesJob] story ingestion failed story_id=#{story[:story_id]}: #{e.class}: #{e.message}")
    nil
  end

  def latest_story_download_event(profile:, story_id:)
    normalized_story_id = story_id.to_s.strip
    return nil if normalized_story_id.blank?

    event = profile.instagram_profile_events
      .joins(:media_attachment)
      .with_attached_media
      .where(kind: "story_downloaded")
      .where("metadata ->> 'story_id' = ?", normalized_story_id)
      .order(detected_at: :desc, id: :desc)
      .first
    return event if event

    escaped_story_id = ActiveRecord::Base.sanitize_sql_like(normalized_story_id)
    profile.instagram_profile_events
      .joins(:media_attachment)
      .with_attached_media
      .where(kind: "story_downloaded")
      .where("external_id LIKE ?", "story_downloaded:#{escaped_story_id}:%")
      .order(detected_at: :desc, id: :desc)
      .first
  end

  def load_existing_story_media(event:)
    return nil unless event&.media&.attached?

    blob = event.media.blob
    {
      event: event,
      blob: blob,
      bytes: blob.download,
      content_type: blob.content_type.to_s.presence || "application/octet-stream",
      filename: blob.filename.to_s.presence || "story_#{event.id}.bin"
    }
  rescue StandardError
    nil
  end

  def load_existing_story_media_from_ingested_story(profile:, story_id:)
    normalized_story_id = story_id.to_s.strip
    return nil if normalized_story_id.blank?

    record = InstagramStory
      .joins(:media_attachment)
      .where(instagram_profile_id: profile.id, story_id: normalized_story_id)
      .order(taken_at: :desc, id: :desc)
      .first
    return nil unless record&.media&.attached?

    blob = record.media.blob
    {
      event: latest_story_download_event(profile: profile, story_id: normalized_story_id),
      blob: blob,
      bytes: blob.download,
      content_type: blob.content_type.to_s.presence || "application/octet-stream",
      filename: blob.filename.to_s.presence || "story_#{record.id}.bin"
    }
  rescue StandardError
    nil
  end

  def load_cached_story_media_for_profile(account:, profile:, story:, skip_reason: nil)
    story_id = story[:story_id].to_s.strip
    return nil if story_id.blank?

    cache_hit = find_cached_story_media(story_id: story_id, excluding_profile_id: profile.id)
    return nil unless cache_hit

    event = build_cached_story_download_event(
      account: account,
      profile: profile,
      story: story,
      story_id: story_id,
      blob: cache_hit[:blob],
      cache_source: cache_hit[:source],
      cache_source_id: cache_hit[:source_id],
      skip_reason: skip_reason
    )
    return nil unless event

    load_existing_story_media(event: event)
  rescue StandardError => e
    Rails.logger.warn("[SyncInstagramProfileStoriesJob] cached media reuse failed for story_id=#{story_id}: #{e.class}: #{e.message}")
    nil
  end

  def attach_blob_to_event(event, blob:)
    return unless event
    return unless blob
    return if event.media.attached?

    event.media.attach(blob)
  rescue StandardError
    nil
  end

  def find_cached_story_media(story_id:, excluding_profile_id:)
    cached_story = InstagramStory
      .joins(:media_attachment)
      .where(story_id: story_id)
      .where.not(instagram_profile_id: excluding_profile_id)
      .order(taken_at: :desc, id: :desc)
      .first
    if cached_story&.media&.attached?
      return { blob: cached_story.media.blob, source: "instagram_story", source_id: cached_story.id }
    end

    escaped_story_id = ActiveRecord::Base.sanitize_sql_like(story_id.to_s)
    cached_event = InstagramProfileEvent
      .joins(:media_attachment)
      .with_attached_media
      .where(kind: "story_downloaded")
      .where.not(instagram_profile_id: excluding_profile_id)
      .where(
        "(metadata ->> 'story_id' = :story_id) OR (external_id LIKE :legacy)",
        story_id: story_id.to_s,
        legacy: "story_downloaded:#{escaped_story_id}:%"
      )
      .order(detected_at: :desc, id: :desc)
      .first
    return nil unless cached_event&.media&.attached?

    { blob: cached_event.media.blob, source: "instagram_profile_event", source_id: cached_event.id }
  end

  def build_cached_story_download_event(account:, profile:, story:, story_id:, blob:, cache_source:, cache_source_id:, skip_reason: nil)
    downloaded_at = Time.current
    metadata = base_story_metadata(profile: profile, story: story).merge(
      downloaded_at: downloaded_at.iso8601,
      media_filename: blob.filename.to_s,
      media_content_type: blob.content_type.to_s,
      media_bytes: blob.byte_size.to_i,
      reused_local_cache: true,
      reused_local_cache_source: cache_source.to_s,
      reused_local_cache_source_id: cache_source_id
    )
    metadata[:skip_reason] = skip_reason.to_s if skip_reason.present?
    metadata[:skipped] = true if skip_reason.present?

    event = profile.record_event!(
      kind: "story_downloaded",
      external_id: story_download_external_id(story_id),
      occurred_at: downloaded_at,
      metadata: metadata
    )
    event.media.attach(blob) unless event.media.attached?
    InstagramProfileEvent.broadcast_story_archive_refresh!(account: account)
    event
  end

  def story_download_external_id(story_id)
    "story_downloaded:#{story_id.to_s.strip}"
  end

  def capture_story_html_snapshot(profile:, story:, story_index:)
    return unless story.present?

    begin
      # Create debug directory if it doesn't exist
      debug_dir = Rails.root.join("tmp", "story_debug_snapshots")
      FileUtils.mkdir_p(debug_dir) unless Dir.exist?(debug_dir)

      # Generate filename with timestamp and story info
      timestamp = Time.current.strftime("%Y%m%d_%H%M%S_%L")
      filename = "#{profile.username}_story_#{story_index}_#{story[:story_id]}_#{timestamp}.html"
      filepath = File.join(debug_dir, filename)

      # Create HTML content with story metadata and DOM structure analysis
      html_content = <<~HTML
        <!DOCTYPE html>
        <html>
        <head>
          <title>Story Debug Snapshot - #{profile.username} - Story #{story_index}</title>
          <style>
            body { font-family: Arial, sans-serif; margin: 20px; }
            .header { background: #f0f0f0; padding: 10px; border-radius: 5px; margin-bottom: 20px; }
            .metadata { background: #fff9e6; padding: 10px; border-radius: 5px; margin-bottom: 20px; }
            .analysis { background: #e6f3ff; padding: 10px; border-radius: 5px; margin-bottom: 20px; }
            .events { background: #ffe6e6; padding: 10px; border-radius: 5px; }
            pre { background: #f5f5f5; padding: 10px; border-radius: 3px; overflow-x: auto; }
            .story-id { color: #0066cc; font-weight: bold; }
            .skip-reason { color: #cc0000; font-weight: bold; }
          </style>
        </head>
        <body>
          <div class="header">
            <h1>Story Debug Snapshot</h1>
            <p><strong>Profile:</strong> #{profile.username} (ID: #{profile.id})</p>
            <p><strong>Story Index:</strong> #{story_index} / #{Array(story).size}</p>
            <p><strong>Captured At:</strong> #{Time.current.iso8601}</p>
          </div>

          <div class="metadata">
            <h2>Story Metadata</h2>
            <pre>#{JSON.pretty_generate(story)}</pre>
          </div>

          <div class="analysis">
            <h2>Processing Analysis</h2>
            <p><strong>Story ID:</strong> <span class="story-id">#{story[:story_id]}</span></p>
            <p><strong>Already Processed:</strong> #{already_processed_story?(profile: profile, story_id: story[:story_id].to_s)}</p>
            <p><strong>Media URL:</strong> #{story[:media_url]}</p>
            <p><strong>Taken At:</strong> #{story[:taken_at]}</p>
            <p><strong>Expiring At:</strong> #{story[:expiring_at]}</p>
          </div>

          <div class="events">
            <h2>Recent Story Events for this Profile</h2>
            <pre>#{JSON.pretty_generate(recent_story_events_for_debug(profile: profile))}</pre>
          </div>
        </body>
        </html>
      HTML

      # Write HTML snapshot to file
      File.write(filepath, html_content)

      # Log the snapshot creation
      Rails.logger.info "[STORY_DEBUG] HTML snapshot created: #{filepath}"

      # Record snapshot event in the database
      profile.record_event!(
        kind: "story_html_snapshot",
        external_id: "story_html_snapshot:#{story[:story_id]}:#{timestamp}",
        occurred_at: Time.current,
        metadata: base_story_metadata(profile: profile, story: story).merge(
          snapshot_filename: filename,
          snapshot_path: filepath,
          story_index: story_index,
          captured_at: Time.current.iso8601
        )
      )

    rescue StandardError => e
      Rails.logger.error "[STORY_DEBUG] Failed to capture HTML snapshot: #{e.message}"
      # Don't fail the entire job if snapshot capture fails
    end
  end

  def recent_story_events_for_debug(profile:)
    profile.instagram_profile_events
      .where(kind: [ "story_uploaded", "story_viewed", "story_analyzed", "story_skipped_debug" ])
      .order(occurred_at: :desc, id: :desc)
      .limit(20)
      .map do |event|
        {
          id: event.id,
          kind: event.kind,
          external_id: event.external_id,
          occurred_at: event.occurred_at&.iso8601,
          metadata: event.metadata.is_a?(Hash) ? event.metadata.slice("story_id", "skip_reason", "force_analyze_all", "story_index", "total_stories") : {}
        }
      end
  end
end
