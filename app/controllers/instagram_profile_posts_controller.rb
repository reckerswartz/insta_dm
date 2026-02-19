class InstagramProfilePostsController < ApplicationController
  include ProfilePostPreviewSupport

  before_action :require_current_account!

  def analyze
    profile = current_account.instagram_profiles.find(params[:instagram_profile_id])
    post = profile.instagram_profile_posts.find(params[:id])

    if analysis_in_progress?(post)
      message = "Post analysis already running for #{post.shortcode}."
      respond_to do |format|
        format.html { redirect_back fallback_location: instagram_profile_path(profile), notice: message }
        format.turbo_stream do
          profile_posts = profile.instagram_profile_posts.includes(:instagram_profile_post_comments, :ai_analyses, { instagram_post_faces: :instagram_story_person }, media_attachment: :blob, preview_image_attachment: :blob).recent_first.limit(100)
          render turbo_stream: [
            turbo_stream.append(
              "notifications",
              partial: "shared/notification",
              locals: { kind: "notice", message: message }
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
        format.json { render json: { message: message }, status: :accepted }
      end
      return
    end

    post.update!(ai_status: "pending", analyzed_at: nil)

    task_flags = {
      analyze_visual: boolean_param(params[:analyze_visual], default: true),
      analyze_faces: boolean_param(params[:analyze_faces], default: true),
      run_ocr: boolean_param(params[:run_ocr], default: true),
      run_video: boolean_param(params[:run_video], default: true),
      run_metadata: boolean_param(params[:run_metadata], default: true),
      generate_comments: boolean_param(params[:generate_comments], default: true),
      enforce_comment_evidence_policy: boolean_param(params[:enforce_comment_evidence_policy], default: false),
      retry_on_incomplete_profile: boolean_param(params[:retry_on_incomplete_profile], default: false)
    }

    AnalyzeInstagramProfilePostJob.perform_later(
      instagram_account_id: current_account.id,
      instagram_profile_id: profile.id,
      instagram_profile_post_id: post.id,
      task_flags: task_flags
    )

    respond_to do |format|
      format.html { redirect_back fallback_location: instagram_profile_path(profile), notice: "Post analysis queued for #{post.shortcode}." }
      format.turbo_stream do
        profile_posts = profile.instagram_profile_posts.includes(:instagram_profile_post_comments, :ai_analyses, { instagram_post_faces: :instagram_story_person }, media_attachment: :blob, preview_image_attachment: :blob).recent_first.limit(100)
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

  def analyze_next_batch
    profile = current_account.instagram_profiles.find(params[:instagram_profile_id])
    offset = params[:offset].to_i || 50
    batch_size = 10

    # Find unanalyzed posts starting from the offset
    unanalyzed_posts = profile.instagram_profile_posts
      .where.not(ai_status: "analyzed")
      .or(profile.instagram_profile_posts.where(ai_status: nil))
      .order(:taken_at)
      .offset(offset)
      .limit(batch_size)

    if unanalyzed_posts.empty?
      message = "No more posts to analyze."
      respond_to do |format|
        format.html { redirect_back fallback_location: instagram_profile_path(profile), notice: message }
        format.turbo_stream do
          render turbo_stream: turbo_stream.append(
            "notifications",
            partial: "shared/notification",
            locals: { kind: "notice", message: message }
          )
        end
        format.json { render json: { message: message }, status: :ok }
      end
      return
    end

    # Create action log for this batch
    action_log = profile.instagram_profile_action_logs.create!(
      instagram_account: current_account,
      action: "analyze_profile_posts_batch",
      status: "queued",
      trigger_source: "ui",
      occurred_at: Time.current,
      metadata: {
        requested_by: "InstagramProfilePostsController",
        offset: offset,
        batch_size: batch_size,
        post_ids: unanalyzed_posts.pluck(:id),
        analysis_batch: "next_#{batch_size}_from_#{offset}"
      }
    )

    # Queue analysis job
    job = AnalyzeCapturedInstagramProfilePostsJob.perform_later(
      instagram_account_id: current_account.id,
      instagram_profile_id: profile.id,
      profile_action_log_id: action_log.id,
      post_ids: unanalyzed_posts.pluck(:id),
      refresh_profile_insights: false
    )
    action_log.update!(active_job_id: job.job_id, queue_name: job.queue_name)

    message = "Queued analysis for next #{unanalyzed_posts.length} posts (posts #{offset + 1}-#{offset + unanalyzed_posts.length})."
    respond_to do |format|
      format.html { redirect_back fallback_location: instagram_profile_path(profile), notice: message }
      format.turbo_stream do
        profile_posts = profile.instagram_profile_posts.includes(:instagram_profile_post_comments, :ai_analyses, { instagram_post_faces: :instagram_story_person }, media_attachment: :blob, preview_image_attachment: :blob).recent_first.limit(100)
        render turbo_stream: [
          turbo_stream.append(
            "notifications",
            partial: "shared/notification",
            locals: { kind: "notice", message: message }
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
      format.json { render json: { message: message, job_id: job.job_id }, status: :accepted }
    end
  rescue StandardError => e
    respond_to do |format|
      format.html { redirect_back fallback_location: instagram_profile_path(params[:instagram_profile_id]), alert: "Unable to queue batch analysis: #{e.message}" }
      format.turbo_stream do
        render turbo_stream: turbo_stream.append(
          "notifications",
          partial: "shared/notification",
          locals: { kind: "alert", message: "Unable to queue batch analysis: #{e.message}" }
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

  private

  def boolean_param(value, default:)
    return default if value.nil?

    ActiveModel::Type::Boolean.new.cast(value)
  end

  def analysis_in_progress?(post)
    metadata = post.metadata
    return false unless metadata.is_a?(Hash)

    pipeline = metadata["ai_pipeline"]
    return false unless pipeline.is_a?(Hash)
    return false unless pipeline["status"].to_s == "running"

    required_steps = Array(pipeline["required_steps"]).map(&:to_s)
    return false if required_steps.empty?

    terminal_statuses = Ai::PostAnalysisPipelineState::TERMINAL_STATUSES
    required_steps.any? do |step|
      !terminal_statuses.include?(pipeline.dig("steps", step, "status").to_s)
    end
  rescue StandardError
    false
  end
end
