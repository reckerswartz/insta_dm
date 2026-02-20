class SyncHomeStoryCarouselJob < ApplicationJob
  queue_as :story_downloads

  STORY_BATCH_LIMIT = 10
  STORY_SYNC_LOCK_NAMESPACE = 92_401

  retry_on Net::OpenTimeout, Net::ReadTimeout, wait: :polynomially_longer, attempts: 3
  retry_on Errno::ECONNRESET, Errno::ECONNREFUSED, wait: :polynomially_longer, attempts: 3
  selenium_timeout_error = "Selenium::WebDriver::Error::TimeoutError".safe_constantize
  retry_on selenium_timeout_error, wait: :polynomially_longer, attempts: 2 if selenium_timeout_error

  def perform(instagram_account_id:, story_limit: STORY_BATCH_LIMIT, auto_reply_only: false)
    lock_acquired = false
    account = InstagramAccount.find(instagram_account_id)
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

    result = Instagram::Client.new(account: account).sync_home_story_carousel!(
      story_limit: limit,
      auto_reply_only: tagged_only
    )

    has_failure = result[:stories_visited].to_i.zero? || result[:failed].to_i.positive?
    message =
      if has_failure
        "Home story sync finished with errors: visited=#{result[:stories_visited]}, failed=#{result[:failed]}, downloaded=#{result[:downloaded]}, analyzed=#{result[:analyzed]}, commented=#{result[:commented]}, reacted=#{result[:reacted]}, skipped_video=#{result[:skipped_video]}, skipped_ads=#{result[:skipped_ads]}, skipped_invalid_media=#{result[:skipped_invalid_media]}, skipped_unreplyable=#{result[:skipped_unreplyable]}, skipped_interaction_retry=#{result[:skipped_interaction_retry]}, skipped_reshared_external_link=#{result[:skipped_reshared_external_link]}, skipped_out_of_network=#{result[:skipped_out_of_network]}."
      else
        "Home story sync complete: visited=#{result[:stories_visited]}, downloaded=#{result[:downloaded]}, analyzed=#{result[:analyzed]}, commented=#{result[:commented]}, reacted=#{result[:reacted]}, skipped_video=#{result[:skipped_video]}, skipped_ads=#{result[:skipped_ads]}, skipped_invalid_media=#{result[:skipped_invalid_media]}, skipped_unreplyable=#{result[:skipped_unreplyable]}, skipped_interaction_retry=#{result[:skipped_interaction_retry]}, skipped_reshared_external_link=#{result[:skipped_reshared_external_link]}, skipped_out_of_network=#{result[:skipped_out_of_network]}."
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
    Turbo::StreamsChannel.broadcast_append_to(
      account,
      target: "notifications",
      partial: "shared/notification",
      locals: { kind: "alert", message: "Home story sync failed: #{e.message}" }
    ) if account
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
end
