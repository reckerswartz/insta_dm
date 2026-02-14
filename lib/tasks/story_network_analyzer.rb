#!/usr/bin/env ruby

require "json"
require "uri"

class StoryNetworkAnalyzer
  DEBUG_GLOB = "log/instagram_debug/**/*.json".freeze

  def initialize(debug_glob: DEBUG_GLOB)
    @debug_glob = debug_glob
  end

  def analyze!
    files = Dir.glob(Rails.root.join(@debug_glob).to_s).sort

    endpoint_counts = Hash.new(0)
    endpoint_statuses = Hash.new { |h, k| h[k] = Hash.new(0) }
    story_graphql_counts = Hash.new(0)
    story_graphql_samples = Hash.new { |h, k| h[k] = [] }
    story_api_counts = Hash.new(0)
    story_api_samples = Hash.new { |h, k| h[k] = [] }

    files.each do |file|
      json = parse_json(File.read(file))
      next unless json.is_a?(Hash)

      logs = json["performance_logs"]
      next unless logs.is_a?(Array)

      request_meta = Hash.new { |h, k| h[k] = {} }

      logs.each do |entry|
        raw = entry.is_a?(Hash) ? entry["message"].to_s : ""
        outer = parse_json(raw)
        inner = outer.is_a?(Hash) ? outer["message"] : nil
        next unless inner.is_a?(Hash)

        method = inner["method"].to_s
        params = inner["params"].is_a?(Hash) ? inner["params"] : {}
        request_id = params["requestId"].to_s

        case method
        when "Network.requestWillBeSent"
          request = params["request"].is_a?(Hash) ? params["request"] : {}
          url = request["url"].to_s
          next if url.blank?

          endpoint = normalize_endpoint(url)
          next if endpoint.blank?

          endpoint_counts[endpoint] += 1
          request_meta[request_id][:endpoint] = endpoint if request_id.present?

          if story_api_endpoint?(endpoint)
            story_api_counts[endpoint] += 1
            add_sample(story_api_samples[endpoint], file)
          end
        when "Network.requestWillBeSentExtraInfo"
          headers = params["headers"].is_a?(Hash) ? params["headers"] : {}
          path = header_value(headers, ":path")
          friendly = header_value(headers, "x-fb-friendly-name")
          root_field = header_value(headers, "x-root-field-name")

          endpoint = normalize_endpoint(path)
          if endpoint.present?
            endpoint_counts[endpoint] += 1
            request_meta[request_id][:endpoint] = endpoint if request_id.present?
          end

          if story_graphql_signature?(friendly: friendly, root_field: root_field)
            key = [ endpoint.presence || "(unknown_path)", friendly, root_field ]
            story_graphql_counts[key] += 1
            add_sample(story_graphql_samples[key], file)
          end
        when "Network.responseReceived"
          status = params.dig("response", "status").to_i
          endpoint = request_meta.dig(request_id, :endpoint)
          next if endpoint.blank?

          endpoint_statuses[endpoint][status] += 1
        end
      end
    end

    {
      generated_at: Time.current.utc.iso8601(3),
      files_scanned: files.length,
      top_endpoints: sort_hash(endpoint_counts).first(80).map do |endpoint, count|
        {
          endpoint: endpoint,
          count: count,
          statuses: sort_hash(endpoint_statuses[endpoint]).to_h
        }
      end,
      story_graphql_signatures: sort_hash(story_graphql_counts).map do |(endpoint, friendly, root_field), count|
        {
          endpoint: endpoint,
          friendly_name: friendly,
          root_field: root_field,
          count: count,
          sample_files: story_graphql_samples[[ endpoint, friendly, root_field ]]
        }
      end,
      story_api_endpoints: sort_hash(story_api_counts).map do |endpoint, count|
        {
          endpoint: endpoint,
          count: count,
          sample_files: story_api_samples[endpoint]
        }
      end
    }
  end

  private

  def parse_json(raw)
    JSON.parse(raw)
  rescue StandardError
    nil
  end

  def normalize_endpoint(value)
    raw = value.to_s.strip
    return "" if raw.blank?

    if raw.start_with?("http://", "https://")
      uri = URI.parse(raw)
      path = uri.path.to_s
      query = uri.query.to_s
      query.present? ? "#{path}?#{query}" : path
    else
      raw
    end
  rescue StandardError
    ""
  end

  def header_value(headers, key)
    return "" unless headers.is_a?(Hash)

    headers[key].to_s.presence ||
      headers[key.downcase].to_s.presence ||
      headers[key.upcase].to_s.presence ||
      ""
  end

  def story_graphql_signature?(friendly:, root_field:)
    friendly_s = friendly.to_s
    root_s = root_field.to_s

    friendly_s.include?("StoriesV3") ||
      root_s.include?("__stories__") ||
      root_s.include?("__reels_") ||
      root_s.include?("__feed__reels")
  end

  def story_api_endpoint?(endpoint)
    endpoint_s = endpoint.to_s

    endpoint_s.include?("/api/v1/feed/reels_media/") ||
      endpoint_s.include?("/api/v1/stories/") ||
      endpoint_s.include?("/api/v1/story_interactions/") ||
      endpoint_s.include?("/api/v1/direct_v2/threads/broadcast/reel_share/") ||
      endpoint_s.include?("/stories/")
  end

  def add_sample(sample_array, file)
    return unless sample_array.is_a?(Array)

    relative = Pathname.new(file).relative_path_from(Rails.root).to_s
    sample_array << relative unless sample_array.include?(relative)
    sample_array.slice!(3..-1) if sample_array.length > 3
  end

  def sort_hash(hash)
    hash.to_a.sort_by { |(_, value)| -value.to_i }
  end
end
