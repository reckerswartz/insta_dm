module Instagram
  class Client
    module MediaSourcePolicy
      BLOCKED_HOST_PATTERNS = [
        /(^|\.)doubleclick\.net\z/i,
        /(^|\.)googlesyndication\.com\z/i,
        /(^|\.)googletagservices\.com\z/i,
        /(^|\.)adservice\.google\./i,
        /(^|\.)taboola\.com\z/i,
        /(^|\.)outbrain\.com\z/i
      ].freeze

      AD_URL_MARKERS = %w[
        _nc_ad=
        ad_urlgen
        ad_image
        ads_image
        sponsored
        promoted
        paid_partnership
        advertisement
      ].freeze

      PROMOTIONAL_QUERY_KEYS = %w[
        ad_id
        adset_id
        campaign_id
      ].freeze

      UTM_PROMOTIONAL_MARKERS = %w[
        ig_ads
        instagram_ads
        facebook_ads
        paid
        sponsored
        promoted
        promo
      ].freeze

      module_function

      def blocked_source_context(url:)
        uri = parse_http_uri(url)
        return nil unless uri

        host = uri.host.to_s.downcase
        path = uri.path.to_s.downcase
        query = uri.query.to_s.downcase
        joined = "#{host}#{path}?#{query}"

        marker = AD_URL_MARKERS.find { |token| joined.include?(token) }
        if marker.present?
          return build_context(
            reason_code: "ad_related_media_source",
            marker: marker,
            confidence: marker == "_nc_ad=" ? "low" : "high",
            source: "url_marker"
          )
        end

        blocked_host = BLOCKED_HOST_PATTERNS.find { |pattern| host.match?(pattern) }
        if blocked_host
          return build_context(
            reason_code: "promotional_media_host",
            marker: blocked_host.source.to_s,
            confidence: "high",
            source: "host_pattern"
          )
        end

        query_params = Rack::Utils.parse_nested_query(uri.query.to_s)
        promotional_query_marker = promotional_query_marker(query_params)
        return nil if promotional_query_marker.blank?

        build_context(
          reason_code: "promotional_media_query",
          marker: promotional_query_marker,
          confidence: "medium",
          source: "query"
        )
      rescue StandardError
        nil
      end

      def parse_http_uri(url)
        value = url.to_s.strip
        return nil if value.blank?

        uri = URI.parse(value)
        return nil unless uri.is_a?(URI::HTTP) || uri.is_a?(URI::HTTPS)

        uri
      rescue URI::InvalidURIError, ArgumentError
        nil
      end

      def promotional_query_marker(query_params)
        data = query_params.is_a?(Hash) ? query_params : {}

        PROMOTIONAL_QUERY_KEYS.each do |key|
          return key if data[key].present? || data[key.to_sym].present?
        end

        utm_source = value_as_text(data["utm_source"] || data[:utm_source])
        utm_medium = value_as_text(data["utm_medium"] || data[:utm_medium])
        utm_campaign = value_as_text(data["utm_campaign"] || data[:utm_campaign])

        values = [ utm_source, utm_medium, utm_campaign ].join(" ")
        marker = UTM_PROMOTIONAL_MARKERS.find { |entry| values.include?(entry) }
        marker.present? ? "utm:#{marker}" : nil
      rescue StandardError
        nil
      end

      def value_as_text(value)
        case value
        when Array
          value.flatten.map(&:to_s).join(" ").downcase
        when Hash
          value.values.flatten.map(&:to_s).join(" ").downcase
        else
          value.to_s.downcase
        end
      end

      def build_context(reason_code:, marker:, confidence:, source:)
        {
          blocked: true,
          reason_code: reason_code.to_s,
          marker: marker.to_s,
          confidence: confidence.to_s,
          source: source.to_s
        }
      end
    end
  end
end
