class SyncHomeStoryCarouselJob < ApplicationJob
  queue_as :story_downloads

  STORY_BATCH_LIMIT = 10

  retry_on Net::OpenTimeout, Net::ReadTimeout, wait: :polynomially_longer, attempts: 3
  retry_on Errno::ECONNRESET, Errno::ECONNREFUSED, wait: :polynomially_longer, attempts: 3
  selenium_timeout_error = "Selenium::WebDriver::Error::TimeoutError".safe_constantize
  retry_on selenium_timeout_error, wait: :polynomially_longer, attempts: 2 if selenium_timeout_error

  def perform(instagram_account_id:, story_limit: STORY_BATCH_LIMIT, auto_reply_only: false)
    account = InstagramAccount.find(instagram_account_id)
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
  end
end
