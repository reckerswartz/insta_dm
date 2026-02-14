require "digest"
require "uri"
require "cgi"

class FetchInstagramProfileDetailsJob < ApplicationJob
  queue_as :profiles

  def perform(instagram_account_id:, instagram_profile_id:, profile_action_log_id: nil)
    account = InstagramAccount.find(instagram_account_id)
    profile = account.instagram_profiles.find(instagram_profile_id)
    action_log = find_or_create_action_log(
      account: account,
      profile: profile,
      action: "fetch_profile_details",
      profile_action_log_id: profile_action_log_id
    )
    action_log.mark_running!(extra_metadata: { queue_name: queue_name, active_job_id: job_id })

    details = Instagram::Client.new(account: account).fetch_profile_details_and_verify_messageability!(username: profile.username)

    prev_last_post_at = profile.last_post_at
    prev_pic_url = profile.profile_pic_url.to_s

    profile.update!(
      display_name: details[:display_name].presence || profile.display_name,
      profile_pic_url: details[:profile_pic_url].presence || profile.profile_pic_url,
      ig_user_id: details[:ig_user_id].presence || profile.ig_user_id,
      bio: details[:bio].presence || profile.bio,
      can_message: details[:can_message],
      restriction_reason: details[:restriction_reason],
      dm_interaction_state: details[:dm_state].to_s.presence || (details[:can_message] ? "messageable" : "unavailable"),
      dm_interaction_reason: details[:dm_reason].to_s.presence || details[:restriction_reason].to_s,
      dm_interaction_checked_at: Time.current,
      dm_interaction_retry_after_at: details[:dm_retry_after_at],
      last_post_at: details[:last_post_at].presence || profile.last_post_at
    )

    profile.recompute_last_active!
    profile.save!

    # Record post activity (best-effort from API profile payload).
    if profile.last_post_at.present? && (prev_last_post_at.nil? || profile.last_post_at > prev_last_post_at)
      eid =
        details[:latest_post_shortcode].presence ||
        "post:#{profile.last_post_at.to_i}"
      profile.record_event!(
        kind: "post_detected",
        external_id: eid,
        occurred_at: profile.last_post_at,
        metadata: { source: "profile_page" }
      )
    end

    # If avatar URL changed (or we never downloaded an attachment), refresh in the background.
    new_url = profile.profile_pic_url.to_s.strip
    if new_url.present? && (profile.avatar.blank? || avatar_fp(new_url) != profile.avatar_url_fingerprint.to_s)
      avatar_log = profile.instagram_profile_action_logs.create!(
        instagram_account: account,
        action: "sync_avatar",
        status: "queued",
        trigger_source: "job",
        occurred_at: Time.current,
        metadata: { triggered_by: self.class.name, reason: "profile_pic_changed" }
      )
      avatar_job = DownloadInstagramProfileAvatarJob.perform_later(
        instagram_account_id: account.id,
        instagram_profile_id: profile.id,
        force: false,
        profile_action_log_id: avatar_log.id
      )
      avatar_log.update!(active_job_id: avatar_job.job_id, queue_name: avatar_job.queue_name)
    elsif new_url.blank? && prev_pic_url.present?
      profile.record_event!(kind: "avatar_missing", external_id: "avatar_missing:#{Time.current.utc.to_date.iso8601}", metadata: { source: "profile_page" })
    end

    Turbo::StreamsChannel.broadcast_append_to(
      account,
      target: "notifications",
      partial: "shared/notification",
      locals: { kind: "notice", message: "Fetched profile details for #{profile.username}." }
    )
    action_log.mark_succeeded!(
      extra_metadata: { can_message: profile.can_message, last_post_at: profile.last_post_at&.iso8601 },
      log_text: "Fetched profile details and updated profile attributes"
    )
  rescue StandardError => e
    Turbo::StreamsChannel.broadcast_append_to(
      account,
      target: "notifications",
      partial: "shared/notification",
      locals: { kind: "alert", message: "Profile fetch failed: #{e.message}" }
    )
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

  def avatar_fp(url)
    url = CGI.unescapeHTML(url.to_s)
    uri = URI.parse(url)
    base = "#{uri.host}#{uri.path}"
    Digest::SHA256.hexdigest(base)
  rescue StandardError
    Digest::SHA256.hexdigest(url.to_s)
  end
end
