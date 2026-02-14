require "json"
require "net/http"
require "uri"

module Messaging
  class IntegrationService
    def initialize(api_url: ENV["OFFICIAL_MESSAGING_API_URL"], access_token: ENV["OFFICIAL_MESSAGING_API_TOKEN"])
      @api_url = api_url.to_s.strip
      @access_token = access_token.to_s
    end

    def configured?
      @api_url.present? && @access_token.present?
    end

    def send_text!(recipient_id:, text:, context: {})
      raise "Official messaging integration is not configured" unless configured?

      uri = URI.parse(@api_url)
      req = Net::HTTP::Post.new(uri.request_uri)
      req["Content-Type"] = "application/json"
      req["Authorization"] = "Bearer #{@access_token}"
      req.body = JSON.generate(
        recipient_id: recipient_id.to_s,
        message: text.to_s,
        context: context.to_h
      )

      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = (uri.scheme == "https")
      http.open_timeout = 8
      http.read_timeout = 20

      res = http.request(req)
      body = JSON.parse(res.body.to_s.presence || "{}") rescue {}
      raise "Official messaging API error: HTTP #{res.code}" unless res.is_a?(Net::HTTPSuccess)

      {
        ok: true,
        status: res.code.to_i,
        provider_message_id: body["id"].to_s.presence || body["message_id"].to_s.presence
      }
    end
  end
end
