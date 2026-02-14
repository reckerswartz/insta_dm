require "net/http"
require "digest"

class DownloadInstagramPostMediaJob < ApplicationJob
  queue_as :profiles

  MAX_IMAGE_BYTES = 6 * 1024 * 1024
  MAX_VIDEO_BYTES = 80 * 1024 * 1024

  def perform(instagram_post_id:)
    post = InstagramPost.find(instagram_post_id)
    return if post.media.attached?

    url = post.media_url.to_s.strip
    return if url.blank?

    io, content_type, filename = download(url)
    post.media.attach(io: io, filename: filename, content_type: content_type)
    post.update!(media_downloaded_at: Time.current)
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
    raise "media too large" if body.bytesize > limit

    ext = extension_for_content_type(content_type)
    io = StringIO.new(body)
    io.set_encoding(Encoding::BINARY) if io.respond_to?(:set_encoding)
    [io, content_type, "post_#{Digest::SHA256.hexdigest(url)[0, 12]}.#{ext}"]
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
