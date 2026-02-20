module Instagram
  class Client
    class MediaDownloadService
      DEFAULT_USER_AGENT = "Mozilla/5.0".freeze

      def initialize(base_url:)
        @base_url = base_url
      end

      def call(url:, user_agent:, redirect_limit: 3)
        uri = URI.parse(url.to_s)
        raise "Invalid media URL" unless uri.is_a?(URI::HTTP) || uri.is_a?(URI::HTTPS)

        res = http_request(uri: uri, user_agent: user_agent)

        if res.is_a?(Net::HTTPRedirection) && res["location"].present? && redirect_limit.to_i.positive?
          return call(url: res["location"], user_agent: user_agent, redirect_limit: redirect_limit.to_i - 1)
        end

        raise "Media download failed: HTTP #{res.code}" unless res.is_a?(Net::HTTPSuccess)

        body = res.body.to_s
        raise "Downloaded media is empty" if body.blank?

        content_type = res["content-type"].to_s.split(";").first.presence || "image/jpeg"
        digest = Digest::SHA256.hexdigest("#{uri.path}-#{body.bytesize}")[0, 12]

        {
          bytes: body,
          content_type: content_type,
          filename: "feed_media_#{digest}.#{extension_for_content_type(content_type: content_type)}",
          final_url: uri.to_s
        }
      end

      private

      def http_request(uri:, user_agent:)
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = (uri.scheme == "https")
        http.open_timeout = 10
        http.read_timeout = 30

        req = Net::HTTP::Get.new(uri.request_uri)
        req["User-Agent"] = user_agent.presence || DEFAULT_USER_AGENT
        req["Accept"] = "*/*"
        req["Referer"] = @base_url
        http.request(req)
      end

      def extension_for_content_type(content_type:)
        return "jpg" if content_type.include?("jpeg")
        return "png" if content_type.include?("png")
        return "webp" if content_type.include?("webp")
        return "gif" if content_type.include?("gif")
        return "mp4" if content_type.include?("mp4")
        return "mov" if content_type.include?("quicktime")

        "bin"
      end
    end
  end
end
