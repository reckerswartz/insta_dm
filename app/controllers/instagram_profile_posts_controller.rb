class InstagramProfilePostsController < ApplicationController
  before_action :require_current_account!

  def analyze
    profile = current_account.instagram_profiles.find(params[:instagram_profile_id])
    post = profile.instagram_profile_posts.find(params[:id])

    post.update!(ai_status: "pending") if post.ai_status == "failed"

    AnalyzeInstagramProfilePostJob.perform_later(
      instagram_account_id: current_account.id,
      instagram_profile_id: profile.id,
      instagram_profile_post_id: post.id
    )

    respond_to do |format|
      format.html { redirect_back fallback_location: instagram_profile_path(profile), notice: "Post analysis queued for #{post.shortcode}." }
      format.turbo_stream do
        profile_posts = profile.instagram_profile_posts.includes(:instagram_profile_post_comments, :ai_analyses, media_attachment: :blob).recent_first.limit(100)
        render turbo_stream: [
          turbo_stream.append(
            "notifications",
            partial: "shared/notification",
            locals: { kind: "notice", message: "Post analysis queued for #{post.shortcode}." }
          ),
          turbo_stream.replace(
            "captured_profile_posts_section",
            partial: "instagram_profiles/captured_posts_section",
            locals: {
              profile: profile,
              profile_posts: profile_posts
            }
          )
        ]
      end
      format.json { head :accepted }
    end
  rescue StandardError => e
    respond_to do |format|
      format.html { redirect_back fallback_location: instagram_profile_path(params[:instagram_profile_id]), alert: "Unable to queue post analysis: #{e.message}" }
      format.turbo_stream do
        render turbo_stream: turbo_stream.append(
          "notifications",
          partial: "shared/notification",
          locals: { kind: "alert", message: "Unable to queue post analysis: #{e.message}" }
        )
      end
      format.json { render json: { error: e.message }, status: :unprocessable_entity }
    end
  end

  def forward_comment
    profile = current_account.instagram_profiles.find(params[:instagram_profile_id])
    post = profile.instagram_profile_posts.find(params[:id])
    comment_text = params[:comment].to_s.strip
    raise "Comment cannot be blank" if comment_text.blank?

    media_id = post.metadata.is_a?(Hash) ? post.metadata["media_id"].to_s.strip : ""
    raise "Media id missing for this post. Re-run profile analysis to refresh post metadata." if media_id.blank?

    action_log = profile.instagram_profile_action_logs.create!(
      instagram_account: current_account,
      action: "post_comment",
      status: "queued",
      trigger_source: "ui",
      occurred_at: Time.current,
      metadata: {
        requested_by: "InstagramProfilePostsController",
        post_shortcode: post.shortcode,
        media_id: media_id,
        comment_text: comment_text
      }
    )

    job = PostInstagramProfileCommentJob.perform_later(
      instagram_account_id: current_account.id,
      instagram_profile_id: profile.id,
      instagram_profile_post_id: post.id,
      comment_text: comment_text,
      media_id: media_id,
      profile_action_log_id: action_log.id
    )

    action_log.update!(active_job_id: job.job_id, queue_name: job.queue_name)

    respond_to do |format|
      format.html { redirect_back fallback_location: instagram_profile_path(profile), notice: "Comment queued for #{post.shortcode}." }
      format.turbo_stream do
        action_logs = profile.instagram_profile_action_logs.recent_first.limit(100)
        render turbo_stream: [
          turbo_stream.append(
            "notifications",
            partial: "shared/notification",
            locals: { kind: "notice", message: "Comment queued for #{post.shortcode}." }
          ),
          turbo_stream.replace(
            "action_history_section",
            partial: "instagram_profiles/action_history_section",
            locals: { action_logs: action_logs }
          )
        ]
      end
      format.json { head :accepted }
    end
  rescue StandardError => e
    respond_to do |format|
      format.html { redirect_back fallback_location: instagram_profile_path(params[:instagram_profile_id]), alert: "Unable to queue comment: #{e.message}" }
      format.turbo_stream do
        render turbo_stream: turbo_stream.append(
          "notifications",
          partial: "shared/notification",
          locals: { kind: "alert", message: "Unable to queue comment: #{e.message}" }
        )
      end
      format.json { render json: { error: e.message }, status: :unprocessable_entity }
    end
  end
end
