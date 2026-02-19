require "base64"
require "digest"
require "json"
require "net/http"

class FaceEmbeddingService
  DEFAULT_DIMENSION = 512
  REQUEST_TIMEOUT_SECONDS = 8

  def initialize(service_url: ENV["FACE_EMBEDDING_SERVICE_URL"], dimension: DEFAULT_DIMENSION)
    @service_url = service_url.to_s.strip
    @dimension = dimension.to_i.positive? ? dimension.to_i : DEFAULT_DIMENSION
  end

  def embed(media_payload:, face:)
    vector = nil
    version = nil

    if @service_url.present?
      vector = fetch_external_embedding(media_payload: media_payload, face: face)
      version = "external_service_v1" if vector.present?
    end

    if vector.blank?
      vector = deterministic_embedding(media_payload: media_payload, face: face)
      version = "deterministic_v1"
    end

    {
      vector: normalize(vector),
      version: version
    }
  end

  private

  def fetch_external_embedding(media_payload:, face:)
    uri = URI.parse(@service_url)
    req = Net::HTTP::Post.new(uri.request_uri)
    req["Content-Type"] = "application/json"
    req["Accept"] = "application/json"
    req.body = JSON.generate(
      image_base64: Base64.strict_encode64(media_payload[:image_bytes].to_s),
      bounding_box: face[:bounding_box],
      story_id: media_payload[:story_id].to_s
    )

    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = (uri.scheme == "https")
    http.open_timeout = REQUEST_TIMEOUT_SECONDS
    http.read_timeout = REQUEST_TIMEOUT_SECONDS
    res = http.request(req)
    return nil unless res.is_a?(Net::HTTPSuccess)

    parsed = JSON.parse(res.body.to_s)
    embedding = parsed["embedding"]
    return nil unless embedding.is_a?(Array) && embedding.any?

    embedding.map(&:to_f)
  rescue StandardError
    nil
  end

  def deterministic_embedding(media_payload:, face:)
    seed = [
      media_payload[:story_id].to_s,
      face[:bounding_box].to_h.to_json,
      Digest::SHA256.hexdigest(media_payload[:image_bytes].to_s.byteslice(0, 8192))
    ].join(":")

    out = []
    i = 0
    while out.length < @dimension
      digest = Digest::SHA256.digest("#{seed}:#{i}")
      digest.bytes.each do |byte|
        out << ((byte.to_f / 127.5) - 1.0)
        break if out.length >= @dimension
      end
      i += 1
    end
    out
  end

  def normalize(vector)
    values = Array(vector).map(&:to_f)
    return [] if values.empty?

    norm = Math.sqrt(values.sum { |v| v * v })
    return values if norm <= 0.0

    values.map { |v| (v / norm).round(8) }
  end
end
