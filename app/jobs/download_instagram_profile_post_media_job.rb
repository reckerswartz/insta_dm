require "net/http"
require "digest"
require "stringio"

class DownloadInstagramProfilePostMediaJob < ApplicationJob
  queue_as :post_downloads

  MAX_IMAGE_BYTES = 6 * 1024 * 1024
  MAX_VIDEO_BYTES = 80 * 1024 * 1024

  retry_on Net::OpenTimeout, Net::ReadTimeout, wait: :polynomially_longer, attempts: 4
  retry_on Errno::ECONNRESET, Errno::ECONNREFUSED, wait: :polynomially_longer, attempts: 4
  retry_on Timeout::Error, wait: :polynomially_longer, attempts: 3

  def perform(instagram_account_id:, instagram_profile_id:, instagram_profile_post_id:, trigger_analysis: true)
    account = InstagramAccount.find(instagram_account_id)
    profile = account.instagram_profiles.find(instagram_profile_id)
    post = profile.instagram_profile_posts.find(instagram_profile_post_id)
    trigger_analysis_bool = ActiveModel::Type::Boolean.new.cast(trigger_analysis)

    analysis_state = { queued: false, reason: "analysis_trigger_disabled" }
    download_state = nil
    post.with_lock do
      download_state = ensure_media_downloaded!(profile: profile, post: post)
      should_enqueue_analysis =
        trigger_analysis_bool &&
        %w[downloaded already_downloaded].include?(download_state[:status].to_s)
      if should_enqueue_analysis
        analysis_state = enqueue_analysis_if_allowed!(account: account, profile: profile, post: post)
      elsif trigger_analysis_bool
        analysis_state = { queued: false, reason: "download_not_completed" }
      end
    end

    Ops::StructuredLogger.info(
      event: "profile_post_media_download.completed",
      payload: {
        active_job_id: job_id,
        instagram_account_id: account.id,
        instagram_profile_id: profile.id,
        instagram_profile_post_id: post.id,
        shortcode: post.shortcode,
        download_status: download_state[:status],
        download_source: download_state[:source],
        analysis_queued: analysis_state[:queued],
        analysis_reason: analysis_state[:reason],
        analysis_job_id: analysis_state[:job_id]
      }
    )
  rescue StandardError => e
    mark_download_failed!(post: post, error: e) if defined?(post) && post
    Ops::StructuredLogger.error(
      event: "profile_post_media_download.failed",
      payload: {
        active_job_id: job_id,
        instagram_account_id: account&.id || instagram_account_id,
        instagram_profile_id: profile&.id || instagram_profile_id,
        instagram_profile_post_id: post&.id || instagram_profile_post_id,
        error_class: e.class.name,
        error_message: e.message.to_s
      }
    )
    raise
  end

  private

  def ensure_media_downloaded!(profile:, post:)
    return mark_download_skipped!(profile: profile, post: post, reason: "deleted_from_source") if post_deleted?(post)

    media_url = resolve_media_url(post)
    return mark_download_skipped!(profile: profile, post: post, reason: "missing_media_url") if media_url.blank?

    if post.media.attached?
      record_download_success!(profile: profile, post: post, source: "already_attached", media_url: media_url)
      return { status: "already_downloaded", source: "already_attached" }
    end

    if attach_media_from_local_cache!(post: post)
      record_download_success!(profile: profile, post: post, source: "local_cache", media_url: media_url)
      return { status: "downloaded", source: "local_cache" }
    end

    io = nil
    begin
      io, content_type, filename = download_media(media_url)
      post.media.attach(io: io, filename: filename, content_type: content_type)
      post.update!(
        media_url_fingerprint: Digest::SHA256.hexdigest(media_url),
        metadata: merged_metadata(post: post).merge(
          "download_status" => "downloaded",
          "download_source" => "remote",
          "downloaded_at" => Time.current.utc.iso8601(3),
          "download_error" => nil
        )
      )
      record_download_success!(profile: profile, post: post, source: "remote", media_url: media_url)
      { status: "downloaded", source: "remote" }
    ensure
      io&.close if io.respond_to?(:close)
    end
  end

  def enqueue_analysis_if_allowed!(account:, profile:, post:)
    policy_decision = Instagram::ProfileScanPolicy.new(profile: profile).decision
    if policy_decision[:skip_post_analysis]
      Instagram::ProfileScanPolicy.mark_post_analysis_skipped!(post: post, decision: policy_decision)
      return {
        queued: false,
        reason: "policy_blocked",
        skip_reason_code: policy_decision[:reason_code].to_s
      }
    end

    return { queued: false, reason: "already_analyzed" } if post.ai_status.to_s == "analyzed" && post.analyzed_at.present?

    fingerprint = analysis_enqueue_fingerprint(post)
    metadata = merged_metadata(post: post)
    if post.ai_status.to_s == "pending" && metadata["analysis_enqueued_fingerprint"].to_s == fingerprint
      return { queued: false, reason: "already_queued_for_current_media" }
    end

    job = AnalyzeInstagramProfilePostJob.perform_later(
      instagram_account_id: account.id,
      instagram_profile_id: profile.id,
      instagram_profile_post_id: post.id
    )
    post.update!(
      ai_status: "pending",
      analyzed_at: nil,
      metadata: metadata.merge(
        "analysis_enqueued_at" => Time.current.utc.iso8601(3),
        "analysis_enqueued_by" => self.class.name,
        "analysis_enqueued_fingerprint" => fingerprint,
        "analysis_job_id" => job.job_id
      )
    )
    profile.record_event!(
      kind: "profile_post_analysis_queued",
      external_id: "profile_post_analysis_queued:#{post.id}:#{fingerprint}",
      occurred_at: Time.current,
      metadata: {
        source: self.class.name,
        instagram_profile_post_id: post.id,
        shortcode: post.shortcode,
        analysis_job_id: job.job_id
      }
    )

    { queued: true, reason: "queued", job_id: job.job_id }
  rescue StandardError => e
    Rails.logger.warn(
      "[DownloadInstagramProfilePostMediaJob] analysis queue failed for post_id=#{post.id}: #{e.class}: #{e.message}"
    )
    { queued: false, reason: "analysis_enqueue_failed", error_class: e.class.name, error_message: e.message.to_s }
  end

  def record_download_success!(profile:, post:, source:, media_url:)
    now = Time.current
    post.update!(
      metadata: merged_metadata(post: post).merge(
        "download_status" => "downloaded",
        "download_source" => source.to_s,
        "downloaded_at" => now.utc.iso8601(3),
        "download_error" => nil
      )
    )
    profile.record_event!(
      kind: "profile_post_media_downloaded",
      external_id: "profile_post_media_downloaded:#{post.id}:#{analysis_enqueue_fingerprint(post)}",
      occurred_at: now,
      metadata: {
        source: self.class.name,
        instagram_profile_post_id: post.id,
        shortcode: post.shortcode,
        media_url: media_url,
        download_source: source.to_s,
        media_attached: post.media.attached?
      }
    )
  end

  def mark_download_skipped!(profile:, post:, reason:)
    post.update!(
      metadata: merged_metadata(post: post).merge(
        "download_status" => "skipped",
        "download_skip_reason" => reason.to_s,
        "download_error" => nil,
        "downloaded_at" => nil
      )
    )
    profile.record_event!(
      kind: "profile_post_media_download_skipped",
      external_id: "profile_post_media_download_skipped:#{post.id}:#{reason}",
      occurred_at: Time.current,
      metadata: {
        source: self.class.name,
        instagram_profile_post_id: post.id,
        shortcode: post.shortcode,
        reason: reason.to_s
      }
    )
    { status: "skipped", source: reason.to_s }
  end

  def mark_download_failed!(post:, error:)
    post.update!(
      metadata: merged_metadata(post: post).merge(
        "download_status" => "failed",
        "download_error" => "#{error.class}: #{error.message}",
        "downloaded_at" => nil
      )
    )
  rescue StandardError
    nil
  end

  def post_deleted?(post)
    ActiveModel::Type::Boolean.new.cast(merged_metadata(post: post)["deleted_from_source"])
  end

  def resolve_media_url(post)
    primary = post.source_media_url.to_s.strip
    return primary if primary.present?

    metadata = merged_metadata(post: post)
    metadata["media_url_video"].to_s.strip.presence || metadata["media_url_image"].to_s.strip.presence
  end

  def merged_metadata(post:)
    post.metadata.is_a?(Hash) ? post.metadata.deep_dup : {}
  end

  def analysis_enqueue_fingerprint(post)
    return "blob:#{post.media.blob.checksum}" if post.media.attached? && post.media.blob&.checksum.to_s.present?
    return "fp:#{post.media_url_fingerprint}" if post.media_url_fingerprint.to_s.present?

    source = resolve_media_url(post)
    return "url:#{Digest::SHA256.hexdigest(source)}" if source.present?

    "post:#{post.id}"
  end

  def attach_media_from_local_cache!(post:)
    blob = cached_media_blob_for(post: post)
    return false unless blob

    source_url = resolve_media_url(post)
    fingerprint = source_url.present? ? Digest::SHA256.hexdigest(source_url) : post.media_url_fingerprint.to_s.presence
    post.media.attach(blob)
    post.update!(
      media_url_fingerprint: fingerprint
    )
    true
  rescue StandardError => e
    Rails.logger.warn("[DownloadInstagramProfilePostMediaJob] local media cache attach failed post_id=#{post.id}: #{e.class}: #{e.message}")
    false
  end

  def cached_media_blob_for(post:)
    metadata = merged_metadata(post: post)
    media_id = metadata["media_id"].to_s.strip
    shortcode = post.shortcode.to_s.strip

    if media_id.present?
      by_media_id = InstagramProfilePost
        .joins(:media_attachment)
        .where.not(id: post.id)
        .where("metadata ->> 'media_id' = ?", media_id)
        .order(updated_at: :desc, id: :desc)
        .first
      return by_media_id.media.blob if by_media_id&.media&.attached?
    end

    if shortcode.present?
      by_shortcode_profile = InstagramProfilePost
        .joins(:media_attachment)
        .where.not(id: post.id)
        .where(shortcode: shortcode)
        .order(updated_at: :desc, id: :desc)
        .first
      return by_shortcode_profile.media.blob if by_shortcode_profile&.media&.attached?

      by_shortcode_feed = InstagramPost
        .joins(:media_attachment)
        .where(shortcode: shortcode)
        .order(media_downloaded_at: :desc, id: :desc)
        .first
      return by_shortcode_feed.media.blob if by_shortcode_feed&.media&.attached?
    end

    nil
  end

  def download_media(url, redirects_left: 4)
    uri = URI.parse(url)
    raise "invalid media URL" unless uri.is_a?(URI::HTTP) || uri.is_a?(URI::HTTPS)

    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = (uri.scheme == "https")
    http.open_timeout = 10
    http.read_timeout = 30

    req = Net::HTTP::Get.new(uri.request_uri)
    req["Accept"] = "*/*"
    req["User-Agent"] = "Mozilla/5.0"
    req["Referer"] = Instagram::Client::INSTAGRAM_BASE_URL
    res = http.request(req)

    if res.is_a?(Net::HTTPRedirection) && res["location"].present?
      raise "too many redirects" if redirects_left.to_i <= 0

      next_url = normalize_redirect_url(base_uri: uri, location: res["location"])
      raise "invalid redirect URL" if next_url.blank?

      return download_media(next_url, redirects_left: redirects_left.to_i - 1)
    end

    raise "media download failed: HTTP #{res.code}" unless res.is_a?(Net::HTTPSuccess)

    body = res.body.to_s
    content_type = res["content-type"].to_s.split(";").first.presence || "application/octet-stream"
    limit = content_type.start_with?("video/") ? MAX_VIDEO_BYTES : MAX_IMAGE_BYTES
    raise "media too large" if body.bytesize > limit

    ext = extension_for_content_type(content_type)
    io = StringIO.new(body)
    io.set_encoding(Encoding::BINARY) if io.respond_to?(:set_encoding)
    [io, content_type, "profile_post_#{Digest::SHA256.hexdigest(url)[0, 12]}.#{ext}"]
  end

  def normalize_redirect_url(base_uri:, location:)
    target = URI.join(base_uri.to_s, location.to_s).to_s
    parsed = URI.parse(target)
    return nil unless parsed.is_a?(URI::HTTP) || parsed.is_a?(URI::HTTPS)

    parsed.to_s
  rescue URI::InvalidURIError, ArgumentError
    nil
  end

  def extension_for_content_type(content_type)
    return "jpg" if content_type.include?("jpeg")
    return "png" if content_type.include?("png")
    return "webp" if content_type.include?("webp")
    return "gif" if content_type.include?("gif")
    return "mp4" if content_type.include?("mp4")
    return "mov" if content_type.include?("quicktime")

    "bin"
  end
end
