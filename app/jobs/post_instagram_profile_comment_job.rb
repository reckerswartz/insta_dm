class PostInstagramProfileCommentJob < ApplicationJob
  queue_as :messages

  def perform(instagram_account_id:, instagram_profile_id:, instagram_profile_post_id:, comment_text:, media_id:, profile_action_log_id: nil)
    account = InstagramAccount.find(instagram_account_id)
    profile = account.instagram_profiles.find(instagram_profile_id)
    post = profile.instagram_profile_posts.find(instagram_profile_post_id)
    action_log = profile.instagram_profile_action_logs.find_by(id: profile_action_log_id)
    action_log&.mark_running!(extra_metadata: { queue_name: queue_name, active_job_id: job_id })

    result = Instagram::Client.new(account: account).post_comment_to_media!(
      media_id: media_id.to_s,
      shortcode: post.shortcode.to_s,
      comment_text: comment_text.to_s
    )

    profile.record_event!(
      kind: "post_comment_sent",
      external_id: "post_comment_sent:#{media_id}:#{Time.current.utc.iso8601(6)}",
      occurred_at: Time.current,
      metadata: {
        source: "profile_post_suggestion_modal",
        post_shortcode: post.shortcode,
        media_id: media_id.to_s,
        comment_text: comment_text.to_s,
        api_result: result
      }
    )

    action_log&.mark_succeeded!(
      extra_metadata: { post_shortcode: post.shortcode, media_id: media_id.to_s },
      log_text: "Comment posted on #{post.shortcode}"
    )

    Turbo::StreamsChannel.broadcast_append_to(
      account,
      target: "notifications",
      partial: "shared/notification",
      locals: { kind: "notice", message: "Comment posted on #{post.shortcode}." }
    )
  rescue StandardError => e
    action_log&.mark_failed!(error_message: e.message, extra_metadata: { active_job_id: job_id, media_id: media_id.to_s })
    Turbo::StreamsChannel.broadcast_append_to(
      account,
      target: "notifications",
      partial: "shared/notification",
      locals: { kind: "alert", message: "Comment post failed: #{e.message}" }
    ) if defined?(account) && account
    raise
  end
end
