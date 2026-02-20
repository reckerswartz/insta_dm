class AutoEngageHomeFeedJob < ApplicationJob
  queue_as :engagements

  def perform(instagram_account_id:, max_posts: 3, include_story: true, story_hold_seconds: 18)
    account = InstagramAccount.find_by(id: instagram_account_id)
    unless account
      Ops::StructuredLogger.info(
        event: "feed_auto_engagement.skipped_missing_account",
        payload: { instagram_account_id: instagram_account_id }
      )
      return
    end

    result = Instagram::Client.new(account: account).auto_engage_home_feed!(
      max_posts: max_posts,
      include_story: include_story,
      story_hold_seconds: story_hold_seconds
    )

    Turbo::StreamsChannel.broadcast_append_to(
      account,
      target: "notifications",
      partial: "shared/notification",
      locals: {
        kind: "notice",
        message: "Auto engagement completed for #{account.username}: posts_commented=#{result[:posts_commented]}, story_replied=#{result[:story_replied]}."
      }
    )
  rescue StandardError => e
    account ||= InstagramAccount.where(id: instagram_account_id).first
    Turbo::StreamsChannel.broadcast_append_to(
      account,
      target: "notifications",
      partial: "shared/notification",
      locals: { kind: "alert", message: "Auto engagement failed: #{e.message}" }
    ) if account
    raise
  end
end
