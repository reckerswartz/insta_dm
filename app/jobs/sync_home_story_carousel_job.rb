class SyncHomeStoryCarouselJob < ApplicationJob
  queue_as :home_story_sync

  STORY_BATCH_LIMIT = 10
  STORY_SYNC_LOCK_NAMESPACE = 92_401

  retry_on Net::OpenTimeout, Net::ReadTimeout, wait: :polynomially_longer, attempts: 3
  retry_on Errno::ECONNRESET, Errno::ECONNREFUSED, wait: :polynomially_longer, attempts: 3
  selenium_timeout_error = "Selenium::WebDriver::Error::TimeoutError".safe_constantize
  retry_on selenium_timeout_error, wait: :polynomially_longer, attempts: 2 if selenium_timeout_error

  def perform(instagram_account_id:, story_limit: STORY_BATCH_LIMIT, auto_reply_only: false)
    lock_acquired = false
    action_log = nil
    run_started_at = nil
    account = InstagramAccount.find_by(id: instagram_account_id)
    unless account
      Ops::StructuredLogger.warn(
        event: "job.account_not_found",
        payload: {
          active_job_id: job_id,
          job_class: self.class.name,
          instagram_account_id: instagram_account_id
        }
      )
      return
    end

    lock_acquired = claim_story_sync_lock!(account_id: account.id)
    unless lock_acquired
      Ops::StructuredLogger.info(
        event: "story_sync.skipped_duplicate_execution",
        payload: {
          active_job_id: job_id,
          instagram_account_id: account.id
        }
      )
      return
    end

    limit = story_limit.to_i.clamp(1, STORY_BATCH_LIMIT)
    tagged_only = ActiveModel::Type::Boolean.new.cast(auto_reply_only)
    run_started_at = Time.current
    account_profile = account.instagram_profiles.find_or_create_by!(username: account.username)
    action_log = create_story_sync_action_log(
      account: account,
      profile: account_profile,
      story_limit: limit,
      auto_reply_only: tagged_only
    )

    client = Instagram::Client.new(account: account)

    # Check if the required method exists before calling
    unless client.respond_to?(:sync_home_story_carousel!, true)
      Ops::StructuredLogger.error(
        event: "job.method_missing",
        payload: {
          active_job_id: job_id,
          job_class: self.class.name,
          instagram_account_id: account.id,
          missing_method: "sync_home_story_carousel!"
        }
      )
      raise NoMethodError, "private method 'sync_home_story_carousel!' called for an instance of Instagram::Client"
    end

    result = client.sync_home_story_carousel!(
      story_limit: limit,
      auto_reply_only: tagged_only
    )

    failure_reasons = recent_story_sync_failure_reasons(account: account, since: run_started_at)
    primary_failure_reason = failure_reasons.max_by { |_reason, count| count.to_i }&.first.to_s.presence
    has_failure = result[:stories_visited].to_i.zero? || result[:failed].to_i.positive?
    reason_suffix = primary_failure_reason.present? ? ", reason=#{primary_failure_reason}" : ""
    summary = sync_result_summary(result: result)
    message =
      if has_failure
        "Home story sync finished with errors#{reason_suffix}: #{summary}."
      else
        "Home story sync complete: #{summary}."
      end

    metadata = {
      active_job_id: job_id,
      queue_name: queue_name,
      story_limit: limit,
      auto_reply_only: tagged_only,
      summary: summarize_sync_result_hash(result: result),
      has_failure: has_failure,
      primary_failure_reason: primary_failure_reason,
      failure_reasons: failure_reasons
    }.compact
    synced_at = Time.current
    account.update!(last_synced_at: synced_at)
    account_profile.update!(last_synced_at: synced_at)
    metadata[:synced_at] = synced_at.iso8601(3)
    if has_failure
      action_log&.mark_failed!(error_message: message, extra_metadata: metadata)
    else
      action_log&.mark_succeeded!(log_text: message, extra_metadata: metadata)
    end

    Turbo::StreamsChannel.broadcast_append_to(
      account,
      target: "notifications",
      partial: "shared/notification",
      locals: {
        kind: has_failure ? "alert" : "notice",
        message: message
      }
    )
  rescue StandardError => e
    account ||= InstagramAccount.where(id: instagram_account_id).first
    action_log&.mark_failed!(
      error_message: "Home story sync failed: #{e.message}",
      extra_metadata: {
        active_job_id: job_id,
        queue_name: queue_name,
        error_class: e.class.name,
        error_message: e.message.to_s.byteslice(0, 500),
        story_limit: story_limit.to_i,
        auto_reply_only: ActiveModel::Type::Boolean.new.cast(auto_reply_only),
        started_at: run_started_at&.iso8601
      }.compact
    )
    Turbo::StreamsChannel.broadcast_append_to(
      account,
      target: "notifications",
      partial: "shared/notification",
      locals: { kind: "alert", message: "Home story sync failed: #{e.message}" }
    ) if account
    record_job_failure_event(
      account: account,
      error: e,
      story_limit: story_limit,
      auto_reply_only: auto_reply_only
    )
    raise
  ensure
    release_story_sync_lock!(account_id: account.id) if lock_acquired && account
  end

  private

  def claim_story_sync_lock!(account_id:)
    return true unless postgres_adapter?

    key_a, key_b = story_sync_lock_keys(account_id: account_id)
    value = ActiveRecord::Base.connection.select_value("SELECT pg_try_advisory_lock(#{key_a}, #{key_b})")
    ActiveModel::Type::Boolean.new.cast(value)
  rescue StandardError => e
    Rails.logger.warn("[SyncHomeStoryCarouselJob] lock claim failed for account_id=#{account_id}: #{e.class}: #{e.message}")
    true
  end

  def release_story_sync_lock!(account_id:)
    return unless postgres_adapter?

    key_a, key_b = story_sync_lock_keys(account_id: account_id)
    ActiveRecord::Base.connection.select_value("SELECT pg_advisory_unlock(#{key_a}, #{key_b})")
  rescue StandardError => e
    Rails.logger.warn("[SyncHomeStoryCarouselJob] lock release failed for account_id=#{account_id}: #{e.class}: #{e.message}")
    nil
  end

  def story_sync_lock_keys(account_id:)
    [ STORY_SYNC_LOCK_NAMESPACE, account_id.to_i ]
  end

  def postgres_adapter?
    ActiveRecord::Base.connection.adapter_name.to_s.downcase.include?("postgres")
  rescue StandardError
    false
  end

  def create_story_sync_action_log(account:, profile:, story_limit:, auto_reply_only:)
    profile.instagram_profile_action_logs.create!(
      instagram_account: account,
      action: "sync_stories_debug",
      status: "running",
      trigger_source: auto_reply_only ? "account_sync_stories_with_comments" : "account_sync_profile_stories",
      occurred_at: Time.current,
      started_at: Time.current,
      active_job_id: job_id,
      queue_name: queue_name,
      metadata: {
        requested_by: self.class.name,
        story_limit: story_limit.to_i,
        auto_reply_only: ActiveModel::Type::Boolean.new.cast(auto_reply_only)
      }
    )
  rescue StandardError
    nil
  end

  def recent_story_sync_failure_reasons(account:, since:)
    return {} unless account && since

    counts = Hash.new(0)
    InstagramProfileEvent
      .joins(:instagram_profile)
      .where(instagram_profiles: { instagram_account_id: account.id })
      .where(kind: %w[story_sync_failed story_sync_job_failed])
      .where("COALESCE(instagram_profile_events.occurred_at, instagram_profile_events.detected_at, instagram_profile_events.created_at) >= ?", since)
      .order(id: :desc)
      .limit(500)
      .each do |event|
        metadata = event.metadata.is_a?(Hash) ? event.metadata : {}
        reason = metadata["reason"].to_s.presence || metadata["skip_reason"].to_s.presence || event.kind.to_s
        counts[reason] += 1
      end
    counts
  rescue StandardError
    {}
  end

  def sync_result_summary(result:)
    summary = summarize_sync_result_hash(result: result)
    "visited=#{summary[:stories_visited]}, failed=#{summary[:failed]}, downloaded=#{summary[:downloaded]}, analyzed=#{summary[:analyzed]}, commented=#{summary[:commented]}, reacted=#{summary[:reacted]}, skipped_video=#{summary[:skipped_video]}, skipped_ads=#{summary[:skipped_ads]}, skipped_invalid_media=#{summary[:skipped_invalid_media]}, skipped_unreplyable=#{summary[:skipped_unreplyable]}, skipped_interaction_retry=#{summary[:skipped_interaction_retry]}, skipped_reshared_external_link=#{summary[:skipped_reshared_external_link]}, skipped_out_of_network=#{summary[:skipped_out_of_network]}"
  end

  def summarize_sync_result_hash(result:)
    {
      stories_visited: result[:stories_visited].to_i,
      failed: result[:failed].to_i,
      downloaded: result[:downloaded].to_i,
      analyzed: result[:analyzed].to_i,
      commented: result[:commented].to_i,
      reacted: result[:reacted].to_i,
      skipped_video: result[:skipped_video].to_i,
      skipped_ads: result[:skipped_ads].to_i,
      skipped_invalid_media: result[:skipped_invalid_media].to_i,
      skipped_unreplyable: result[:skipped_unreplyable].to_i,
      skipped_interaction_retry: result[:skipped_interaction_retry].to_i,
      skipped_reshared_external_link: result[:skipped_reshared_external_link].to_i,
      skipped_out_of_network: result[:skipped_out_of_network].to_i
    }
  end

  def record_job_failure_event(account:, error:, story_limit:, auto_reply_only:)
    return unless account

    profile = account.instagram_profiles.find_or_create_by!(username: account.username)
    profile.record_event!(
      kind: "story_sync_job_failed",
      external_id: "story_sync_job_failed:home_carousel:#{Time.current.utc.iso8601(6)}",
      occurred_at: Time.current,
      metadata: {
        source: "home_story_carousel",
        reason: "job_exception",
        story_limit: story_limit.to_i,
        auto_reply_only: ActiveModel::Type::Boolean.new.cast(auto_reply_only),
        active_job_id: job_id,
        error_class: error.class.name,
        error_message: error.message.to_s.byteslice(0, 500)
      }
    )
  rescue StandardError
    nil
  end
end
