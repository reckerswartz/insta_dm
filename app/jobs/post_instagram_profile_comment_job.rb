class PostInstagramProfileCommentJob < ApplicationJob
  queue_as :messages

  def perform(instagram_account_id:, instagram_profile_id:, instagram_profile_post_id:, comment_text:, media_id:, profile_action_log_id: nil)
    account = InstagramAccount.find(instagram_account_id)
    profile = account.instagram_profiles.find(instagram_profile_id)
    post = profile.instagram_profile_posts.find(instagram_profile_post_id)
    action_log = profile.instagram_profile_action_logs.find_by(id: profile_action_log_id)
    action_log&.mark_running!(extra_metadata: { queue_name: queue_name, active_job_id: job_id })

    guard = comment_posting_guard(post: post)
    unless ActiveModel::Type::Boolean.new.cast(guard[:allow])
      reason = guard[:reason].to_s.presence || "Post is not suitable for engagement."
      action_log&.mark_failed!(
        error_message: reason,
        extra_metadata: {
          active_job_id: job_id,
          media_id: media_id.to_s,
          blocked_reason_code: guard[:reason_code].to_s
        }
      )
      Turbo::StreamsChannel.broadcast_append_to(
        account,
        target: "notifications",
        partial: "shared/notification",
        locals: { kind: "alert", message: "Comment skipped for #{post.shortcode}: #{reason}" }
      )
      return
    end

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

  private

  def comment_posting_guard(post:)
    metadata = post.metadata.is_a?(Hash) ? post.metadata : {}
    policy = metadata["comment_generation_policy"].is_a?(Hash) ? metadata["comment_generation_policy"] : {}
    reason_code = policy["blocked_reason_code"].to_s
    reason = policy["blocked_reason"].to_s

    if policy["status"].to_s == "blocked" && reason_code.in?(%w[unsuitable_for_engagement low_relevance_suggestions])
      return {
        allow: false,
        reason_code: reason_code,
        reason: reason.presence || "Comment blocked by engagement suitability policy."
      }
    end

    classification = policy["engagement_classification"]
    classification = metadata["engagement_classification"] unless classification.is_a?(Hash)
    if classification.is_a?(Hash)
      ownership = classification["ownership"].to_s
      same_owner =
        if classification.key?("same_profile_owner_content")
          ActiveModel::Type::Boolean.new.cast(classification["same_profile_owner_content"])
        end
      content_type = classification["content_type"].to_s
      blocked_content_type = %w[meme quote music_share religious_viral promotional generic_reshared reshared_content].include?(content_type)

      if same_owner == false || (ownership.present? && ownership != "original")
        return {
          allow: false,
          reason_code: "ownership_mismatch",
          reason: "Post ownership is not original to this profile."
        }
      end

      if blocked_content_type
        return {
          allow: false,
          reason_code: "unsuitable_content_type",
          reason: "Post content type '#{content_type}' is excluded from engagement."
        }
      end

      if classification.key?("engagement_suitable") &&
          !ActiveModel::Type::Boolean.new.cast(classification["engagement_suitable"])
        return {
          allow: false,
          reason_code: "unsuitable_for_engagement",
          reason: classification["summary"].to_s.presence || "Post is classified as unsuitable for engagement."
        }
      end
    end

    { allow: true }
  rescue StandardError
    { allow: true }
  end
end
