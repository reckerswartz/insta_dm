require "net/http"
require "digest"

class DownloadInstagramPostMediaJob < ApplicationJob
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

  def perform(instagram_post_id:)
    post = InstagramPost.find(instagram_post_id)
    if post.media.attached?
      integrity = blob_integrity_for(post.media.blob)
      return if integrity[:valid]
    end

    url = post.media_url.to_s.strip
    return if url.blank?

    trust_policy = media_download_policy_decision(post: post, media_url: url)
    if ActiveModel::Type::Boolean.new.cast(trust_policy[:blocked])
      mark_download_skipped!(
        post: post,
        reason: trust_policy[:reason_code].to_s.presence || "blocked_media_source",
        details: trust_policy
      )
      return
    end

    return if attach_media_from_local_cache!(post: post)

    io, content_type, filename = download(url)
    blob = ActiveStorage::Blob.create_and_upload!(
      io: io,
      filename: filename,
      content_type: content_type,
      identify: false
    )
    attach_blob_to_post!(post: post, blob: blob)
    post.update!(
      media_downloaded_at: Time.current,
      metadata: merged_metadata(post: post).merge(
        "download_status" => "downloaded",
        "download_skip_reason" => nil,
        "download_skip_details" => nil,
        "download_error" => nil
      )
    )
  rescue BlockedMediaSourceError => e
    mark_download_skipped!(
      post: post,
      reason: e.context[:reason_code].to_s.presence || "blocked_media_source",
      details: e.context
    )
  rescue StandardError
    post&.update!(purge_at: 6.hours.from_now) if post
    raise
  ensure
    begin
      io&.close
    rescue StandardError
      nil
    end
  end

  private

  def download(url)
    blocked_context = blocked_source_context(url: url)
    raise BlockedMediaSourceError, blocked_context if blocked_context.present?

    uri = URI.parse(url)
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = (uri.scheme == "https")
    http.open_timeout = 10
    http.read_timeout = 30

    req = Net::HTTP::Get.new(uri.request_uri)
    req["Accept"] = "*/*"
    req["User-Agent"] = "Mozilla/5.0"
    res = http.request(req)
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
    [io, content_type, "post_#{Digest::SHA256.hexdigest(url)[0, 12]}.#{ext}"]
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
  rescue StandardError
    { valid: false, reason: "integrity_check_error" }
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

  def attach_blob_to_post!(post:, blob:)
    raise "missing blob for attach" unless blob

    if post.media.attached? && post.media.attachment.present?
      attachment = post.media.attachment
      attachment.update!(blob: blob) if attachment.blob_id != blob.id
      return
    end

    post.media.attach(blob)
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

  def attach_media_from_local_cache!(post:)
    blob = cached_media_blob_for(post: post)
    return false unless blob

    attach_blob_to_post!(post: post, blob: blob)
    post.update!(
      media_downloaded_at: Time.current,
      metadata: merged_metadata(post: post).merge(
        "download_status" => "downloaded",
        "download_skip_reason" => nil,
        "download_skip_details" => nil,
        "download_error" => nil
      )
    )
    true
  rescue StandardError => e
    Rails.logger.warn("[DownloadInstagramPostMediaJob] local media cache attach failed post_id=#{post.id}: #{e.class}: #{e.message}")
    false
  end

  def cached_media_blob_for(post:)
    shortcode = post.shortcode.to_s.strip
    return nil if shortcode.blank?

    cached_feed_post = InstagramPost
      .joins(:media_attachment)
      .where(shortcode: shortcode)
      .where.not(id: post.id)
      .order(media_downloaded_at: :desc, id: :desc)
      .first
    if cached_feed_post&.media&.attached?
      blob = cached_feed_post.media.blob
      return blob if blob_integrity_for(blob)[:valid]
    end

    cached_profile_post = InstagramProfilePost
      .joins(:media_attachment)
      .where(shortcode: shortcode)
      .order(updated_at: :desc, id: :desc)
      .first
    if cached_profile_post&.media&.attached?
      blob = cached_profile_post.media.blob
      return blob if blob_integrity_for(blob)[:valid]
    end

    nil
  end

  def mark_download_skipped!(post:, reason:, details: nil)
    post.update!(
      media_downloaded_at: nil,
      metadata: merged_metadata(post: post).merge(
        "download_status" => "skipped",
        "download_skip_reason" => reason.to_s,
        "download_skip_details" => normalize_skip_details(details),
        "download_error" => nil
      )
    )
    Ops::StructuredLogger.info(
      event: "feed_post_media_download.skipped",
      payload: {
        instagram_post_id: post.id,
        instagram_account_id: post.instagram_account_id,
        instagram_profile_id: post.instagram_profile_id,
        reason: reason.to_s
      }
    )
  rescue StandardError
    nil
  end

  def media_download_policy_decision(post:, media_url:)
    Instagram::MediaDownloadTrustPolicy.evaluate(
      account: post.instagram_account,
      profile: post.instagram_profile,
      media_url: media_url
    )
  rescue StandardError
    { blocked: false }
  end

  def blocked_source_context(url:)
    Instagram::MediaDownloadTrustPolicy.blocked_source_context(url: url)
  rescue StandardError
    nil
  end

  def merged_metadata(post:)
    post.metadata.is_a?(Hash) ? post.metadata.deep_dup : {}
  end

  def normalize_skip_details(details)
    value = details.is_a?(Hash) ? details.deep_stringify_keys : {}
    value.present? ? value : nil
  rescue StandardError
    nil
  end
end
