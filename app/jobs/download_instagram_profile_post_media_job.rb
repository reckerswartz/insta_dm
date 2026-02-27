require "net/http"
require "digest"
require "stringio"

class DownloadInstagramProfilePostMediaJob < ApplicationJob
  queue_as :post_downloads

  class BlockedMediaSourceError < StandardError
    attr_reader :context

    def initialize(context)
      @context = context.is_a?(Hash) ? context.deep_symbolize_keys : {}
      reason_code = @context[:reason_code].to_s.presence || "blocked_media_source"
      marker = @context[:marker].to_s.presence || "unknown"
      super("Blocked media source: #{reason_code} (#{marker})")
    end
  end

  MAX_IMAGE_BYTES = 6 * 1024 * 1024
  MAX_VIDEO_BYTES = 80 * 1024 * 1024
  MAX_PREVIEW_IMAGE_BYTES = 3 * 1024 * 1024
  PROFILE_POST_PREVIEW_ENQUEUE_TTL_SECONDS = 30.minutes

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
      download_state = ensure_media_downloaded!(account: account, profile: profile, post: post)
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

  def ensure_media_downloaded!(account:, profile:, post:)
    return mark_download_skipped!(profile: profile, post: post, reason: "deleted_from_source") if post_deleted?(post)

    media_url = resolve_media_url(post)
    return mark_download_skipped!(profile: profile, post: post, reason: "missing_media_url") if media_url.blank?

    trust_policy = media_download_policy_decision(account: account, profile: profile, media_url: media_url)
    if ActiveModel::Type::Boolean.new.cast(trust_policy[:blocked])
      return mark_download_skipped!(
        profile: profile,
        post: post,
        reason: trust_policy[:reason_code].to_s.presence || "blocked_media_source",
        details: trust_policy
      )
    end

    attached_and_valid = false
    if post.media.attached?
      integrity = blob_integrity_for(post.media.blob)
      if integrity[:valid]
        attached_and_valid = true
      else
        mark_corrupt_media_detected!(post: post, reason: integrity[:reason])
      end
    end

    if attached_and_valid
      ensure_preview_image_for_video!(post: post, media_url: media_url)
      record_download_success!(profile: profile, post: post, source: "already_attached", media_url: media_url)
      return { status: "already_downloaded", source: "already_attached" }
    end

    if attach_media_from_local_cache!(post: post)
      ensure_preview_image_for_video!(post: post, media_url: media_url)
      record_download_success!(profile: profile, post: post, source: "local_cache", media_url: media_url)
      return { status: "downloaded", source: "local_cache" }
    end

    io = nil
    begin
      io, content_type, filename = download_media(media_url)
      blob = ActiveStorage::Blob.create_and_upload!(
        io: io,
        filename: filename,
        content_type: content_type,
        identify: false
      )
      attach_blob_to_post!(post: post, blob: blob)
      downloaded_bytes = io.respond_to?(:string) ? io.string.to_s : nil
      ensure_preview_image_for_video!(post: post, media_url: media_url, video_bytes: downloaded_bytes, content_type: content_type)
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
    rescue BlockedMediaSourceError => e
      mark_download_skipped!(
        profile: profile,
        post: post,
        reason: e.context[:reason_code].to_s.presence || "blocked_media_source",
        details: e.context
      )
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
      instagram_profile_post_id: post.id,
      task_flags: {
        generate_comments: false,
        enforce_comment_evidence_policy: false,
        retry_on_incomplete_profile: false
      }
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

  def mark_download_skipped!(profile:, post:, reason:, details: nil)
    details_payload = normalized_skip_details(details)
    post.update!(
      metadata: merged_metadata(post: post).merge(
        "download_status" => "skipped",
        "download_skip_reason" => reason.to_s,
        "download_skip_details" => details_payload,
        "download_error" => nil,
        "downloaded_at" => nil
      ).compact
    )
    profile.record_event!(
      kind: "profile_post_media_download_skipped",
      external_id: "profile_post_media_download_skipped:#{post.id}:#{reason}",
      occurred_at: Time.current,
      metadata: {
        source: self.class.name,
        instagram_profile_post_id: post.id,
        shortcode: post.shortcode,
        reason: reason.to_s,
        details: details_payload
      }.compact
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

  def mark_corrupt_media_detected!(post:, reason:)
    post.update!(
      metadata: merged_metadata(post: post).merge(
        "download_status" => "corrupt_detected",
        "download_error" => "integrity_check_failed: #{reason}",
        "download_corrupt_detected_at" => Time.current.utc.iso8601(3)
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
    attach_blob_to_post!(post: post, blob: blob)
    post.update!(
      media_url_fingerprint: fingerprint
    )
    attach_preview_from_local_cache!(post: post)
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
      if by_media_id&.media&.attached? && blob_integrity_for(by_media_id.media.blob)[:valid]
        return by_media_id.media.blob
      end
    end

    if shortcode.present?
      by_shortcode_profile = InstagramProfilePost
        .joins(:media_attachment)
        .where.not(id: post.id)
        .where(shortcode: shortcode)
        .order(updated_at: :desc, id: :desc)
      by_shortcode_profile.each do |candidate|
        next unless candidate&.media&.attached?

        blob = candidate.media.blob
        return blob if blob_integrity_for(blob)[:valid]
      end

      by_shortcode_feed = InstagramPost
        .joins(:media_attachment)
        .where(shortcode: shortcode)
        .order(media_downloaded_at: :desc, id: :desc)
      by_shortcode_feed.each do |candidate|
        next unless candidate&.media&.attached?

        blob = candidate.media.blob
        return blob if blob_integrity_for(blob)[:valid]
      end
    end

    nil
  end

  def attach_preview_from_local_cache!(post:)
    return false if post.preview_image.attached?

    metadata = merged_metadata(post: post)
    media_id = metadata["media_id"].to_s.strip
    shortcode = post.shortcode.to_s.strip

    if media_id.present?
      by_media_id = InstagramProfilePost
        .joins(:preview_image_attachment)
        .where.not(id: post.id)
        .where("metadata ->> 'media_id' = ?", media_id)
        .order(updated_at: :desc, id: :desc)
        .first
      if by_media_id&.preview_image&.attached?
        attach_preview_blob_to_post!(post: post, blob: by_media_id.preview_image.blob)
        return true
      end
    end

    return false if shortcode.blank?

    by_shortcode = InstagramProfilePost
      .joins(:preview_image_attachment)
      .where.not(id: post.id)
      .where(shortcode: shortcode)
      .order(updated_at: :desc, id: :desc)
      .first
    if by_shortcode&.preview_image&.attached?
      attach_preview_blob_to_post!(post: post, blob: by_shortcode.preview_image.blob)
      return true
    end

    false
  rescue StandardError
    false
  end

  def ensure_preview_image_for_video!(post:, media_url:, video_bytes: nil, content_type: nil)
    return false unless post.media.attached?
    return false unless post.media.blob&.content_type.to_s.start_with?("video/")
    return true if post.preview_image.attached?

    metadata = merged_metadata(post: post)
    if attach_preview_from_local_cache!(post: post)
      stamp_preview_metadata!(post: post, source: "local_cache")
      return true
    end

    poster_url = preferred_preview_image_url(post: post, media_url: media_url, metadata: metadata)
    if poster_url.present?
      downloaded = download_preview_image(poster_url)
      if downloaded
        attach_preview_image_bytes!(
          post: post,
          image_bytes: downloaded[:bytes],
          content_type: downloaded[:content_type],
          filename: downloaded[:filename]
        )
        stamp_preview_metadata!(post: post, source: "remote_image_url")
        return true
      end
    end

    bytes = video_bytes.to_s.b
    if bytes.blank? && post.media.attached? && post.media.blob.byte_size.to_i <= MAX_VIDEO_BYTES
      bytes = post.media.blob.download.to_s.b
    end
    if bytes.blank?
      enqueue_background_preview_generation!(post: post, reason: "video_bytes_missing")
      return false
    end

    extracted = VideoThumbnailService.new.extract_first_frame(
      video_bytes: bytes,
      reference_id: "profile_post_#{post.id}",
      content_type: content_type || post.media.blob.content_type
    )
    unless extracted[:ok]
      enqueue_background_preview_generation!(post: post, reason: extracted.dig(:metadata, :reason).to_s.presence || "ffmpeg_extract_failed")
      return false
    end

    attach_preview_image_bytes!(
      post: post,
      image_bytes: extracted[:image_bytes],
      content_type: extracted[:content_type],
      filename: extracted[:filename]
    )
    stamp_preview_metadata!(post: post, source: "ffmpeg_first_frame")
    true
  rescue StandardError => e
    Rails.logger.warn("[DownloadInstagramProfilePostMediaJob] preview attach failed post_id=#{post.id}: #{e.class}: #{e.message}")
    enqueue_background_preview_generation!(post: post, reason: "#{e.class}: #{e.message}")
    false
  end

  def preferred_preview_image_url(post:, media_url:, metadata:)
    candidates = [
      metadata["preview_image_url"],
      metadata["poster_url"],
      metadata["image_url"],
      metadata["media_url_image"],
      metadata["media_url"]
    ]
    source_media = post.source_media_url.to_s.strip
    source_looks_video = source_media.downcase.match?(/\.(mp4|mov|webm)(\?|$)/)
    candidates << source_media if source_media.present? && !source_looks_video
    candidates << media_url.to_s if media_url.to_s.present? && !source_looks_video
    candidates.compact.map { |v| v.to_s.strip }.find(&:present?)
  end

  def download_preview_image(url, redirects_left: 3)
    return nil if blocked_source_context(url: url).present?

    uri = URI.parse(url)
    return nil unless uri.is_a?(URI::HTTP) || uri.is_a?(URI::HTTPS)

    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = (uri.scheme == "https")
    http.open_timeout = 8
    http.read_timeout = 20

    req = Net::HTTP::Get.new(uri.request_uri)
    req["Accept"] = "image/*,*/*;q=0.8"
    req["User-Agent"] = "Mozilla/5.0"
    req["Referer"] = Instagram::Client::INSTAGRAM_BASE_URL
    res = http.request(req)

    if res.is_a?(Net::HTTPRedirection) && res["location"].present?
      return nil if redirects_left.to_i <= 0
      next_url = normalize_redirect_url(base_uri: uri, location: res["location"])
      return nil if next_url.blank?

      return download_preview_image(next_url, redirects_left: redirects_left.to_i - 1)
    end

    return nil unless res.is_a?(Net::HTTPSuccess)

    body = res.body.to_s.b
    return nil if body.bytesize <= 0 || body.bytesize > MAX_PREVIEW_IMAGE_BYTES
    return nil if html_payload?(body)

    content_type = res["content-type"].to_s.split(";").first.to_s
    return nil unless content_type.start_with?("image/")
    validate_known_signature!(body: body, content_type: content_type)

    ext = extension_for_content_type(content_type)
    {
      bytes: body,
      content_type: content_type,
      filename: "profile_post_preview_#{Digest::SHA256.hexdigest(url)[0, 12]}.#{ext}"
    }
  rescue StandardError
    nil
  end

  def attach_preview_image_bytes!(post:, image_bytes:, content_type:, filename:)
    blob = ActiveStorage::Blob.create_and_upload!(
      io: StringIO.new(image_bytes),
      filename: filename,
      content_type: content_type.to_s.presence || "image/jpeg",
      identify: false
    )
    attach_preview_blob_to_post!(post: post, blob: blob)
  end

  def attach_preview_blob_to_post!(post:, blob:)
    return unless blob

    if post.preview_image.attached? && post.preview_image.attachment.present?
      attachment = post.preview_image.attachment
      attachment.update!(blob: blob) if attachment.blob_id != blob.id
      return
    end

    post.preview_image.attach(blob)
  end

  def stamp_preview_metadata!(post:, source:)
    post.update!(
      metadata: merged_metadata(post: post).merge(
        "preview_image_status" => "attached",
        "preview_image_source" => source.to_s,
        "preview_image_attached_at" => Time.current.utc.iso8601(3)
      )
    )
  rescue StandardError
    nil
  end

  def enqueue_background_preview_generation!(post:, reason:)
    return if post.preview_image.attached?
    return unless post.media.attached?
    return unless post.media.blob&.content_type.to_s.start_with?("video/")

    cache_key = "profile_post:preview_enqueue:#{post.id}"
    Rails.cache.fetch(cache_key, expires_in: PROFILE_POST_PREVIEW_ENQUEUE_TTL_SECONDS) do
      GenerateProfilePostPreviewImageJob.perform_later(instagram_profile_post_id: post.id)
      true
    end
  rescue StandardError => e
    Rails.logger.warn(
      "[DownloadInstagramProfilePostMediaJob] preview enqueue failed post_id=#{post.id} " \
      "reason=#{reason}: #{e.class}: #{e.message}"
    )
    nil
  end

  def download_media(url, redirects_left: 4)
    blocked_context = blocked_source_context(url: url)
    raise BlockedMediaSourceError, blocked_context if blocked_context.present?

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
    raise "empty media payload" if body.bytesize <= 0
    raise "media too large" if body.bytesize > limit
    raise "unexpected html payload" if html_payload?(body)
    validate_known_signature!(body: body, content_type: content_type)

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

  def blob_integrity_for(blob)
    return { valid: false, reason: "missing_blob" } unless blob
    return { valid: false, reason: "non_positive_byte_size" } if blob.byte_size.to_i <= 0

    service = blob.service
    if service.respond_to?(:path_for, true)
      path = service.send(:path_for, blob.key)
      return { valid: false, reason: "missing_file_on_disk" } unless path && File.exist?(path)

      file_size = File.size(path)
      return { valid: false, reason: "zero_byte_file" } if file_size <= 0
      return { valid: false, reason: "byte_size_mismatch" } if blob.byte_size.to_i.positive? && file_size != blob.byte_size.to_i
    end

    { valid: true, reason: nil }
  rescue StandardError => e
    { valid: false, reason: "integrity_check_error: #{e.class}" }
  end

  def attach_blob_to_post!(post:, blob:)
    raise "missing blob for attach" unless blob

    if post.media.attached? && post.media.attachment.present?
      attachment = post.media.attachment
      attachment.update!(blob: blob) if attachment.blob_id != blob.id
      return
    end

    post.media.attach(blob)
  end

  def html_payload?(body)
    sample = body.to_s.byteslice(0, 4096).to_s.downcase
    sample.include?("<html") || sample.start_with?("<!doctype html")
  end

  def validate_known_signature!(body:, content_type:)
    type = content_type.to_s.downcase
    return if type.blank?
    return if type.include?("octet-stream")

    case
    when type.include?("jpeg")
      raise "invalid jpeg signature" unless body.start_with?("\xFF\xD8".b)
    when type.include?("png")
      raise "invalid png signature" unless body.start_with?("\x89PNG\r\n\x1A\n".b)
    when type.include?("gif")
      raise "invalid gif signature" unless body.start_with?("GIF87a".b) || body.start_with?("GIF89a".b)
    when type.include?("webp")
      raise "invalid webp signature" unless body.bytesize >= 12 && body.byteslice(0, 4) == "RIFF" && body.byteslice(8, 4) == "WEBP"
    when type.start_with?("video/")
      raise "invalid video signature" unless body.bytesize >= 12 && body.byteslice(4, 4) == "ftyp"
    end
  end

  def blocked_source_context(url:)
    Instagram::MediaDownloadTrustPolicy.blocked_source_context(url: url)
  rescue StandardError
    nil
  end

  def media_download_policy_decision(account:, profile:, media_url:)
    Instagram::MediaDownloadTrustPolicy.evaluate(
      account: account,
      profile: profile,
      media_url: media_url
    )
  rescue StandardError
    { blocked: false }
  end

  def normalized_skip_details(details)
    value = details.is_a?(Hash) ? details.deep_stringify_keys : {}
    value.present? ? value : nil
  rescue StandardError
    nil
  end
end
