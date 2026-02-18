require "cgi"
require "uri"

module Instagram
  class AvatarUrlNormalizer
    PLACEHOLDER_PATTERNS = [
      /\/static\/images\/profile\//i,
      /profile-pic-null/i,
      /default[_-]?profile/i
    ].freeze

    class << self
      def normalize(raw_url)
        url = CGI.unescapeHTML(raw_url.to_s).strip
        return nil if url.blank?

        if url.start_with?("//")
          url = "https:#{url}"
        elsif url.start_with?("/")
          return nil
        elsif !url.match?(%r{\Ahttps?://}i)
          return nil unless url.match?(%r{\A[a-z0-9.-]+\.[a-z]{2,}([/:]|$)}i)

          url = "https://#{url}"
        end

        uri = URI.parse(url)
        return nil unless uri.is_a?(URI::HTTP) || uri.is_a?(URI::HTTPS)
        return nil if uri.host.to_s.blank?
        return nil if placeholder_path?(uri.path.to_s)

        uri.to_s
      rescue URI::InvalidURIError, ArgumentError
        nil
      end

      def placeholder_path?(path)
        normalized = path.to_s.downcase
        return false if normalized.blank?

        PLACEHOLDER_PATTERNS.any? { |pattern| normalized.match?(pattern) }
      end
    end
  end
end
