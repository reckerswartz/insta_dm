require "net/http"
require "digest"
require "stringio"
require "timeout"

class GenerateStoryPreviewImageJob < ApplicationJob
  queue_as :story_preview_generation

  MAX_PREVIEW_IMAGE_BYTES = 3 * 1024 * 1024
  NON_RETRYABLE_PREVIEW_PATTERNS = [
    "invalid data found when processing input",
    "error reading header",
    "could not find corresponding trex",
    "trun track id unknown",
    "no tfhd was found",
    "moov atom not found"
  ].freeze

  retry_on ActiveStorage::PreviewError, wait: :polynomially_longer, attempts: 3
  retry_on Net::OpenTimeout, Net::ReadTimeout, wait: :polynomially_longer, attempts: 3
  retry_on Errno::ECONNRESET, Errno::ECONNREFUSED, wait: :polynomially_longer, attempts: 3
  retry_on Timeout::Error, wait: :polynomially_longer, attempts: 2
  retry_on StandardError, wait: 10.seconds, attempts: 2

  def perform(instagram_profile_event_id:, story_payload: nil, user_agent: nil)
    event = InstagramProfileEvent.find_by(id: instagram_profile_event_id)
    return unless event&.media&.attached?
    return if event.preview_image.attached?
    return unless event.media.blob&.content_type.to_s.start_with?("video/")

    story = normalize_story_payload(story_payload)
    preview_url = preferred_story_preview_url(story: story)
    if preview_url.present?
      downloaded = download_preview_image(url: preview_url, user_agent: user_agent)
      if downloaded
        attach_preview_image_bytes!(
          event: event,
          image_bytes: downloaded[:bytes],
          content_type: downloaded[:content_type],
          filename: downloaded[:filename]
        )
        stamp_preview_success_metadata!(event: event, source: "remote_image_url")
        return
      end
    end

    extracted = VideoThumbnailService.new.extract_first_frame(
      video_bytes: event.media.blob.download.to_s.b,
      reference_id: "story_event_#{event.id}",
      content_type: event.media.blob.content_type.to_s
    )
    if extracted[:ok]
      attach_preview_image_bytes!(
        event: event,
        image_bytes: extracted[:image_bytes],
        content_type: extracted[:content_type],
        filename: extracted[:filename]
      )
      stamp_preview_success_metadata!(event: event, source: "ffmpeg_first_frame")
      return
    end
    if non_retryable_thumbnail_failure?(extracted)
      detail = preview_failure_detail(extracted)
      stamp_preview_failure_metadata!(
        event: event,
        reason: "invalid_video_stream",
        detail: detail
      )
      Rails.logger.warn(
        "[GenerateStoryPreviewImageJob] non-retryable thumbnail failure event_id=#{instagram_profile_event_id}: " \
        "#{detail.to_s.byteslice(0, 500)}"
      )
      return
    end

    attached = attach_preview_via_active_storage!(event: event)
    return if attached

    stamp_preview_failure_metadata!(event: event, reason: "preview_not_generated", detail: "No preview extraction strategy succeeded")
  rescue ActiveStorage::PreviewError => e
    if event && non_retryable_preview_error?(e)
      stamp_preview_failure_metadata!(
        event: event,
        reason: "invalid_video_stream",
        detail: e.message
      )
      Rails.logger.warn(
        "[GenerateStoryPreviewImageJob] non-retryable preview failure event_id=#{instagram_profile_event_id}: " \
        "#{e.class}: #{e.message}"
      )
      return
    end

    Rails.logger.warn("[GenerateStoryPreviewImageJob] failed event_id=#{instagram_profile_event_id}: #{e.class}: #{e.message}")
    raise
  rescue StandardError => e
    Rails.logger.warn("[GenerateStoryPreviewImageJob] failed event_id=#{instagram_profile_event_id}: #{e.class}: #{e.message}")
    raise
  end

  private

  def normalize_story_payload(raw_payload)
    raw = raw_payload.is_a?(Hash) ? raw_payload : {}
    raw.deep_symbolize_keys
  rescue StandardError
    {}
  end

  def preferred_story_preview_url(story:)
    candidates = [
      story[:image_url].to_s,
      story[:thumbnail_url].to_s,
      story[:preview_image_url].to_s
    ]

    Array(story[:carousel_media]).each do |entry|
      data = entry.is_a?(Hash) ? entry : {}
      candidates << data[:image_url].to_s
      candidates << data["image_url"].to_s
    end

    candidates.map(&:strip).find(&:present?)
  rescue StandardError
    nil
  end

  def download_preview_image(url:, user_agent:, redirects_left: 3)
    uri = URI.parse(url)
    return nil unless uri.is_a?(URI::HTTP) || uri.is_a?(URI::HTTPS)

    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = (uri.scheme == "https")
    http.open_timeout = 8
    http.read_timeout = 20

    req = Net::HTTP::Get.new(uri.request_uri)
    req["Accept"] = "image/*,*/*;q=0.8"
    req["User-Agent"] = user_agent.to_s.presence || "Mozilla/5.0"
    req["Referer"] = Instagram::Client::INSTAGRAM_BASE_URL
    res = http.request(req)

    if res.is_a?(Net::HTTPRedirection) && res["location"].present?
      return nil if redirects_left.to_i <= 0

      redirected_url = normalize_redirect_url(base_uri: uri, location: res["location"])
      return nil if redirected_url.blank?

      return download_preview_image(url: redirected_url, user_agent: user_agent, redirects_left: redirects_left.to_i - 1)
    end

    return nil unless res.is_a?(Net::HTTPSuccess)

    body = res.body.to_s.b
    return nil if body.bytesize <= 0 || body.bytesize > MAX_PREVIEW_IMAGE_BYTES
    return nil if html_payload?(body)

    content_type = res["content-type"].to_s.split(";").first.to_s
    return nil unless content_type.start_with?("image/")

    validate_known_signature!(body: body, content_type: content_type)
    ext = extension_for_content_type(content_type: content_type)

    {
      bytes: body,
      content_type: content_type,
      filename: "story_preview_#{Digest::SHA256.hexdigest(url)[0, 12]}.#{ext}"
    }
  rescue StandardError
    nil
  end

  def attach_preview_image_bytes!(event:, image_bytes:, content_type:, filename:)
    blob = ActiveStorage::Blob.create_and_upload!(
      io: StringIO.new(image_bytes),
      filename: filename,
      content_type: content_type.to_s.presence || "image/jpeg",
      identify: false
    )
    attach_preview_blob_to_event!(event: event, blob: blob)
  end

  def attach_preview_via_active_storage!(event:)
    preview = event.media.preview(resize_to_limit: [ 640, 640 ]).processed
    preview_image = preview.image
    return false unless preview_image&.attached?

    event.with_lock do
      return true if event.preview_image.attached?

      event.preview_image.attach(preview_image.blob)
      stamp_preview_success_metadata!(event: event, source: "active_storage_preview_job")
    end

    true
  end

  def attach_preview_blob_to_event!(event:, blob:)
    return unless blob

    if event.preview_image.attached? && event.preview_image.attachment.present?
      attachment = event.preview_image.attachment
      attachment.update!(blob: blob) if attachment.blob_id != blob.id
      return
    end

    event.preview_image.attach(blob)
  end

  def normalize_redirect_url(base_uri:, location:)
    target = URI.join(base_uri.to_s, location.to_s).to_s
    parsed = URI.parse(target)
    return nil unless parsed.is_a?(URI::HTTP) || parsed.is_a?(URI::HTTPS)

    parsed.to_s
  rescue URI::InvalidURIError, ArgumentError
    nil
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
    end
  end

  def extension_for_content_type(content_type:)
    return "jpg" if content_type.include?("jpeg")
    return "png" if content_type.include?("png")
    return "webp" if content_type.include?("webp")

    "bin"
  end

  def non_retryable_preview_error?(error)
    non_retryable_preview_message?(error.to_s)
  end

  def non_retryable_thumbnail_failure?(thumbnail_result)
    metadata = thumbnail_result.is_a?(Hash) ? (thumbnail_result[:metadata] || thumbnail_result["metadata"]) : nil
    return false unless metadata.is_a?(Hash)

    reason = (metadata[:reason] || metadata["reason"]).to_s
    return false unless reason.in?(%w[ffmpeg_extract_failed thumbnail_extraction_error])

    stderr = metadata[:stderr] || metadata["stderr"]
    non_retryable_preview_message?(stderr)
  end

  def preview_failure_detail(thumbnail_result)
    metadata = thumbnail_result.is_a?(Hash) ? (thumbnail_result[:metadata] || thumbnail_result["metadata"]) : nil
    return nil unless metadata.is_a?(Hash)

    stderr = (metadata[:stderr] || metadata["stderr"]).to_s.presence
    return stderr if stderr.present?

    (metadata[:reason] || metadata["reason"]).to_s.presence
  end

  def non_retryable_preview_message?(raw_message)
    message = raw_message.to_s.downcase
    return false if message.blank?

    NON_RETRYABLE_PREVIEW_PATTERNS.any? { |pattern| message.include?(pattern) }
  end

  def stamp_preview_success_metadata!(event:, source:)
    metadata = event.metadata.is_a?(Hash) ? event.metadata.deep_dup : {}
    metadata["preview_image_status"] = "attached"
    metadata["preview_image_source"] = source.to_s
    metadata["preview_image_attached_at"] = Time.current.utc.iso8601(3)
    metadata.delete("preview_image_failed_at")
    metadata.delete("preview_image_failure_reason")
    metadata.delete("preview_image_failure_detail")
    event.update!(metadata: metadata)
  rescue StandardError
    nil
  end

  def stamp_preview_failure_metadata!(event:, reason:, detail:)
    metadata = event.metadata.is_a?(Hash) ? event.metadata.deep_dup : {}
    metadata["preview_image_status"] = "failed"
    metadata["preview_image_source"] = "story_preview_generation_job"
    metadata["preview_image_failed_at"] = Time.current.utc.iso8601(3)
    metadata["preview_image_failure_reason"] = reason.to_s
    snippet = detail.to_s.strip.byteslice(0, 500)
    metadata["preview_image_failure_detail"] = snippet if snippet.present?
    event.update!(metadata: metadata)
  rescue StandardError
    nil
  end
end
