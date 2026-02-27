require "net/http"
require "digest"
require "cgi"
require "uri"

class DownloadInstagramProfileAvatarJob < ApplicationJob
  queue_as :avatars

  class BlockedMediaSourceError < StandardError
    attr_reader :context

    def initialize(context)
      @context = context.is_a?(Hash) ? context.deep_symbolize_keys : {}
      reason_code = @context[:reason_code].to_s.presence || "blocked_media_source"
      marker = @context[:marker].to_s.presence || "unknown"
      super("Blocked media source: #{reason_code} (#{marker})")
    end
  end

  def perform(instagram_account_id:, instagram_profile_id:, broadcast: true, force: false, profile_action_log_id: nil)
    account = InstagramAccount.find(instagram_account_id)
    profile = account.instagram_profiles.find(instagram_profile_id)
    action_log = find_or_create_action_log(
      account: account,
      profile: profile,
      action: "sync_avatar",
      profile_action_log_id: profile_action_log_id
    )
    action_log.mark_running!(extra_metadata: { queue_name: queue_name, active_job_id: job_id, force: force })

    raw_url = profile.profile_pic_url.to_s
    url = Instagram::AvatarUrlNormalizer.normalize(raw_url)
    if url.blank?
      # Nothing to download; leave the attachment blank and allow UI default avatar fallback.
      profile.update!(
        profile_pic_url: (raw_url.present? ? nil : profile.profile_pic_url),
        avatar_url_fingerprint: nil,
        avatar_synced_at: Time.current
      )
      action_log.mark_succeeded!(
        extra_metadata: {
          skipped: true,
          reason: raw_url.present? ? "invalid_or_placeholder_avatar_url" : "avatar_url_blank",
          profile_pic_url_raw: raw_url.presence
        },
        log_text: raw_url.present? ? "Avatar URL invalid/placeholder; skipped download" : "Avatar URL blank; marked as synced with no attachment"
      )
      return
    end

    trust_policy = Instagram::MediaDownloadTrustPolicy.evaluate(
      account: account,
      profile: profile,
      media_url: url
    )
    if ActiveModel::Type::Boolean.new.cast(trust_policy[:blocked])
      profile.update!(avatar_synced_at: Time.current)
      action_log.mark_succeeded!(
        extra_metadata: {
          skipped: true,
          reason: trust_policy[:reason_code].to_s.presence || "blocked_media_source",
          policy: trust_policy,
          profile_pic_url_raw: raw_url.presence
        },
        log_text: "Avatar download skipped by trust policy."
      )
      return
    end

    fp = url_fingerprint(url)

    # Skip if we already have the latest avatar attached.
    if profile.avatar.attached? && !force && profile.avatar_url_fingerprint.to_s == fp
      action_log.mark_succeeded!(log_text: "Avatar unchanged; skipped download", extra_metadata: { skipped: true })
      return
    end

    io, filename, content_type = fetch_url(url, user_agent: account.user_agent)

    attach_avatar!(
      profile: profile,
      io: io,
      filename: filename,
      content_type: content_type
    )

    avatar_changed = profile.avatar_url_fingerprint.present? && profile.avatar_url_fingerprint != fp
    profile.update!(avatar_url_fingerprint: fp, avatar_synced_at: Time.current)

    if avatar_changed
      event = profile.record_event!(
        kind: "avatar_changed",
        external_id: fp,
        occurred_at: nil,
        metadata: { profile_pic_url: url }
      )
      begin
        event.media.attach(profile.avatar.blob) if profile.avatar.attached?
      rescue StandardError
        nil
      end
    else
      profile.record_event!(
        kind: "avatar_synced",
        external_id: fp,
        occurred_at: nil,
        metadata: { profile_pic_url: url }
      )
    end

    if broadcast
      Turbo::StreamsChannel.broadcast_append_to(
        account,
        target: "notifications",
        partial: "shared/notification",
        locals: { kind: "notice", message: "Downloaded avatar for #{profile.username}." }
      )
    end
    action_log.mark_succeeded!(
      extra_metadata: { fingerprint: fp, avatar_changed: avatar_changed, profile_pic_url: url },
      log_text: "Avatar sync complete"
    )
  rescue BlockedMediaSourceError => e
    profile&.update!(avatar_synced_at: Time.current)
    action_log&.mark_succeeded!(
      extra_metadata: {
        skipped: true,
        reason: e.context[:reason_code].to_s.presence || "blocked_media_source",
        policy: e.context
      },
      log_text: "Avatar download skipped by trust policy."
    )
  rescue StandardError => e
    if broadcast
      Turbo::StreamsChannel.broadcast_append_to(
        account,
        target: "notifications",
        partial: "shared/notification",
        locals: { kind: "alert", message: "Avatar download failed: #{e.message}" }
      )
    end
    action_log&.mark_failed!(error_message: e.message, extra_metadata: { active_job_id: job_id })
    raise
  end

  private

  def attach_avatar!(profile:, io:, filename:, content_type:)
    attachment = profile.avatar_attachment

    unless attachment.present?
      profile.avatar.attach(
        io: io,
        filename: filename,
        content_type: content_type
      )
      return
    end

    # Avoid destroying the attachment row because ActiveStorageIngestion keeps
    # a foreign-key reference to attachment ids for storage observability.
    new_blob = ActiveStorage::Blob.create_and_upload!(
      io: io,
      filename: filename,
      content_type: content_type
    )
    attachment.update!(blob: new_blob)
  end

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
  
  def url_fingerprint(url)
    uri = URI.parse(url)
    # Instagram CDN URLs often rotate query params; host+path is the stable signal for "same image".
    base = "#{uri.host}#{uri.path}"
    Digest::SHA256.hexdigest(base)
  rescue StandardError
    Digest::SHA256.hexdigest(url.to_s)
  end

  def fetch_url(url, user_agent:, redirects_left: 4)
    raise "Too many redirects" if redirects_left.negative?
    blocked_context = Instagram::MediaDownloadTrustPolicy.blocked_source_context(url: url)
    raise BlockedMediaSourceError, blocked_context if blocked_context.present?

    uri = URI.parse(url)
    raise "Invalid URL" unless uri.is_a?(URI::HTTP) || uri.is_a?(URI::HTTPS)

    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = (uri.scheme == "https")
    http.open_timeout = 10
    http.read_timeout = 20

    req = Net::HTTP::Get.new(uri.request_uri)
    req["User-Agent"] = user_agent.presence || "Mozilla/5.0"
    req["Accept"] = "image/avif,image/webp,image/apng,image/*,*/*;q=0.8"
    req["Referer"] = "https://www.instagram.com/"

    res = http.request(req)

    # Handle simple redirects (CDN often redirects).
    if res.is_a?(Net::HTTPRedirection) && res["location"].present?
      redirected_url = normalize_redirect_url(base_uri: uri, location: res["location"])
      raise "Invalid redirect URL" if redirected_url.blank?

      return fetch_url(redirected_url, user_agent: user_agent, redirects_left: redirects_left - 1)
    end

    raise "HTTP #{res.code}" unless res.is_a?(Net::HTTPSuccess)

    body = res.body
    raise "Empty response body" if body.blank?

    filename = File.basename(uri.path.presence || "avatar.jpg")
    filename = "avatar.jpg" if filename.blank? || filename == "/"
    content_type = res["content-type"].to_s.split(";").first.presence || "image/jpeg"

    io = StringIO.new(body)
    [io, filename, content_type]
  end

  def normalize_redirect_url(base_uri:, location:)
    target = URI.join(base_uri.to_s, location.to_s).to_s
    uri = URI.parse(target)
    return nil unless uri.is_a?(URI::HTTP) || uri.is_a?(URI::HTTPS)

    uri.to_s
  rescue URI::InvalidURIError, ArgumentError
    nil
  end
end
