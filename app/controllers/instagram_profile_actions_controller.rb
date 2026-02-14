class InstagramProfileActionsController < ApplicationController
  before_action :require_current_account!

  def download_missing_avatars
    DownloadMissingAvatarsJob.perform_later(instagram_account_id: current_account.id)
    respond_to do |format|
      format.html { redirect_back fallback_location: instagram_profiles_path, notice: "Avatar sync queued." }
      format.turbo_stream do
        render turbo_stream: turbo_stream.append(
          "notifications",
          partial: "shared/notification",
          locals: { kind: "notice", message: "Avatar sync queued." }
        )
      end
      format.json { head :accepted }
    end
  rescue StandardError => e
    respond_to do |format|
      format.html { redirect_back fallback_location: instagram_profiles_path, alert: "Unable to queue avatar sync: #{e.message}" }
      format.turbo_stream do
        render turbo_stream: turbo_stream.append(
          "notifications",
          partial: "shared/notification",
          locals: { kind: "alert", message: "Unable to queue avatar sync: #{e.message}" }
        )
      end
      format.json { render json: { error: e.message }, status: :unprocessable_entity }
    end
  end

  def analyze
    profile = current_account.instagram_profiles.find(params[:id])
    enqueue_profile_job(
      profile: profile,
      action: "analyze_profile",
      job_class: AnalyzeInstagramProfileJob
    )

    respond_to do |format|
      format.html { redirect_back fallback_location: instagram_profile_path(profile), notice: "AI analysis queued." }
      format.turbo_stream do
        render turbo_stream: queued_action_streams(profile: profile, message: "AI analysis queued for #{profile.username}.")
      end
      format.json { head :accepted }
    end
  rescue StandardError => e
    respond_to do |format|
      format.html { redirect_back fallback_location: instagram_profile_path(params[:id]), alert: "Unable to queue AI analysis: #{e.message}" }
      format.turbo_stream do
        render turbo_stream: turbo_stream.append(
          "notifications",
          partial: "shared/notification",
          locals: { kind: "alert", message: "Unable to queue AI analysis: #{e.message}" }
        )
      end
      format.json { render json: { error: e.message }, status: :unprocessable_entity }
    end
  end

  def fetch_details
    profile = current_account.instagram_profiles.find(params[:id])
    enqueue_profile_job(
      profile: profile,
      action: "fetch_profile_details",
      job_class: FetchInstagramProfileDetailsJob
    )

    respond_to do |format|
      format.html { redirect_back fallback_location: instagram_profile_path(profile), notice: "Profile fetch queued." }
      format.turbo_stream do
        render turbo_stream: queued_action_streams(profile: profile, message: "Profile fetch queued for #{profile.username}.")
      end
      format.json { head :accepted }
    end
  rescue StandardError => e
    respond_to do |format|
      format.html { redirect_back fallback_location: instagram_profile_path(params[:id]), alert: "Unable to queue fetch: #{e.message}" }
      format.turbo_stream do
        render turbo_stream: turbo_stream.append(
          "notifications",
          partial: "shared/notification",
          locals: { kind: "alert", message: "Unable to queue fetch: #{e.message}" }
        )
      end
      format.json { render json: { error: e.message }, status: :unprocessable_entity }
    end
  end

  def verify_messageability
    profile = current_account.instagram_profiles.find(params[:id])
    enqueue_profile_job(
      profile: profile,
      action: "verify_messageability",
      job_class: VerifyInstagramMessageabilityJob
    )

    respond_to do |format|
      format.html { redirect_back fallback_location: instagram_profile_path(profile), notice: "Messageability check queued." }
      format.turbo_stream do
        render turbo_stream: queued_action_streams(profile: profile, message: "Messageability check queued for #{profile.username}.")
      end
      format.json { head :accepted }
    end
  rescue StandardError => e
    respond_to do |format|
      format.html { redirect_back fallback_location: instagram_profile_path(params[:id]), alert: "Unable to queue messageability check: #{e.message}" }
      format.turbo_stream do
        render turbo_stream: turbo_stream.append(
          "notifications",
          partial: "shared/notification",
          locals: { kind: "alert", message: "Unable to queue messageability check: #{e.message}" }
        )
      end
      format.json { render json: { error: e.message }, status: :unprocessable_entity }
    end
  end

  def download_avatar
    profile = current_account.instagram_profiles.find(params[:id])
    enqueue_profile_job(
      profile: profile,
      action: "sync_avatar",
      job_class: DownloadInstagramProfileAvatarJob
    )

    respond_to do |format|
      format.html { redirect_back fallback_location: instagram_profile_path(profile), notice: "Avatar download queued." }
      format.turbo_stream do
        render turbo_stream: queued_action_streams(profile: profile, message: "Avatar download queued for #{profile.username}.")
      end
      format.json { head :accepted }
    end
  rescue StandardError => e
    respond_to do |format|
      format.html { redirect_back fallback_location: instagram_profile_path(params[:id]), alert: "Unable to queue avatar download: #{e.message}" }
      format.turbo_stream do
        render turbo_stream: turbo_stream.append(
          "notifications",
          partial: "shared/notification",
          locals: { kind: "alert", message: "Unable to queue avatar download: #{e.message}" }
        )
      end
      format.json { render json: { error: e.message }, status: :unprocessable_entity }
    end
  end

  def sync_stories
    profile = current_account.instagram_profiles.find(params[:id])
    enqueue_profile_job(
      profile: profile,
      action: "sync_stories",
      job_class: SyncInstagramProfileStoriesJob,
      extra_job_args: {
        max_stories: 10,
        force_analyze_all: false,
        auto_reply: false
      }
    )

    respond_to do |format|
      format.html { redirect_back fallback_location: instagram_profile_path(profile), notice: "Story sync queued." }
      format.turbo_stream do
        render turbo_stream: queued_action_streams(profile: profile, message: "Story sync queued for #{profile.username}.")
      end
      format.json { head :accepted }
    end
  rescue StandardError => e
    respond_to do |format|
      format.html { redirect_back fallback_location: instagram_profile_path(params[:id]), alert: "Unable to queue story sync: #{e.message}" }
      format.turbo_stream do
        render turbo_stream: turbo_stream.append(
          "notifications",
          partial: "shared/notification",
          locals: { kind: "alert", message: "Unable to queue story sync: #{e.message}" }
        )
      end
      format.json { render json: { error: e.message }, status: :unprocessable_entity }
    end
  end

  def sync_stories_force
    profile = current_account.instagram_profiles.find(params[:id])
    enqueue_profile_job(
      profile: profile,
      action: "sync_stories",
      job_class: SyncInstagramProfileStoriesJob,
      extra_job_args: {
        max_stories: 10,
        force_analyze_all: true,
        auto_reply: false
      }
    )

    respond_to do |format|
      format.html { redirect_back fallback_location: instagram_profile_path(profile), notice: "Force story analysis queued." }
      format.turbo_stream do
        render turbo_stream: queued_action_streams(profile: profile, message: "Force story analysis queued for #{profile.username}.")
      end
      format.json { head :accepted }
    end
  rescue StandardError => e
    respond_to do |format|
      format.html { redirect_back fallback_location: instagram_profile_path(params[:id]), alert: "Unable to queue force story analysis: #{e.message}" }
      format.turbo_stream do
        render turbo_stream: turbo_stream.append(
          "notifications",
          partial: "shared/notification",
          locals: { kind: "alert", message: "Unable to queue force story analysis: #{e.message}" }
        )
      end
      format.json { render json: { error: e.message }, status: :unprocessable_entity }
    end
  end

  def sync_stories_debug
    profile = current_account.instagram_profiles.find(params[:id])
    
    # Clean up existing debug files for this profile
    cleanup_profile_debug_files(profile.username)
    
    enqueue_profile_job(
      profile: profile,
      action: "sync_stories_debug",
      job_class: SyncInstagramProfileStoriesJob,
      extra_job_args: {
        max_stories: 10,
        force_analyze_all: false,
        auto_reply: false
      }
    )

    respond_to do |format|
      format.html { redirect_back fallback_location: instagram_profile_path(profile), notice: "Debug story sync queued. HTML snapshots will be captured." }
      format.turbo_stream do
        render turbo_stream: queued_action_streams(profile: profile, message: "Debug story sync queued for #{profile.username}. HTML snapshots will be captured.")
      end
      format.json { head :accepted }
    end
  rescue StandardError => e
    respond_to do |format|
      format.html { redirect_back fallback_location: instagram_profile_path(params[:id]), alert: "Unable to queue debug story sync: #{e.message}" }
      format.turbo_stream do
        render turbo_stream: turbo_stream.append(
          "notifications",
          partial: "shared/notification",
          locals: { kind: "alert", message: "Unable to queue debug story sync: #{e.message}" }
        )
      end
      format.json { render json: { error: e.message }, status: :unprocessable_entity }
    end
  end

  private

  def queued_action_streams(profile:, message:)
    action_logs = profile.instagram_profile_action_logs.recent_first.limit(100)
    [
      turbo_stream.append(
        "notifications",
        partial: "shared/notification",
        locals: { kind: "notice", message: message }
      ),
      turbo_stream.replace(
        "action_history_section",
        partial: "instagram_profiles/action_history_section",
        locals: { action_logs: action_logs }
      )
    ]
  end

  def enqueue_profile_job(profile:, action:, job_class:, extra_job_args: {})
    log = profile.instagram_profile_action_logs.create!(
      instagram_account: current_account,
      action: action,
      status: "queued",
      trigger_source: "ui",
      occurred_at: Time.current,
      metadata: { requested_by: "InstagramProfileActionsController" }
    )

    begin
      job = job_class.perform_later(
        instagram_account_id: current_account.id,
        instagram_profile_id: profile.id,
        profile_action_log_id: log.id,
        **extra_job_args
      )

      log.update!(
        active_job_id: job.job_id,
        queue_name: job.queue_name
      )
    rescue StandardError => e
      log.mark_failed!(error_message: "Queueing failed: #{e.message}")
      raise
    end
  end

  def cleanup_profile_debug_files(username)
    debug_dirs = [
      Rails.root.join('tmp', 'story_debug_snapshots'),
      Rails.root.join('tmp', 'story_reel_debug')
    ]
    
    debug_dirs.each do |dir|
      next unless Dir.exist?(dir)
      
      # Remove files matching the username pattern
      Dir.glob(File.join(dir, "#{username}_*")).each do |file|
        File.delete(file) if File.exist?(file)
      end
    end
  end
end
