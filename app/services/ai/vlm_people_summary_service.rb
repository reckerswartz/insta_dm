module Ai
  # VLM-based substitute for the legacy face-detection pipeline
  # (Ai::FaceDetectionService + Ai::FaceEmbeddingService +
  # Ai::VectorMatchingService + Ai::FaceIdentityResolutionService).
  #
  # Context: Phase 4 of the NVIDIA migration dropped the Python
  # microservice that ran RetinaFace + InsightFace. NVIDIA Build has no
  # first-class face-detection / face-embedding API, so the
  # "person clustering across posts" features are discontinued. In their
  # place, this service asks an NVIDIA vision model to describe the
  # people visible in a given image -- useful for:
  #   * populating a post's people_count metadata,
  #   * seeding comment prompts with context like "group photo with 3
  #     people, one wearing a jersey",
  #   * surfacing who-is-in-this-story information to operators.
  #
  # The output is persisted under instagram_post_insights.raw_analysis["people"]
  # by downstream callers (wired in Phase 4.5); this service only does
  # the VLM call + JSON coercion.
  class VlmPeopleSummaryService
    DEFAULT_ROLE = "vision_primary".freeze
    DEFAULT_FALLBACK_ROLES = %w[vision_fallback].freeze
    DEFAULT_MAX_TOKENS = 900
    DEFAULT_TEMPERATURE = 0.25
    MAX_PEOPLE_CAP = 30

    Result = Struct.new(:ok, :people_count, :descriptions, :prominent_roles, :scene, :raw, :error, keyword_init: true) do
      def ok?
        ok
      end

      def to_h
        {
          "ok" => ok?,
          "people_count" => people_count,
          "descriptions" => descriptions,
          "prominent_roles" => prominent_roles,
          "scene" => scene,
          "error" => error
        }.compact
      end
    end

    def initialize(provider: nil, role: DEFAULT_ROLE, fallback_roles: DEFAULT_FALLBACK_ROLES, temperature: DEFAULT_TEMPERATURE, max_tokens: DEFAULT_MAX_TOKENS)
      @provider = provider
      @role = role
      @fallback_roles = Array(fallback_roles)
      @temperature = temperature
      @max_tokens = max_tokens
    end

    # image: one of
    #   - Hash { bytes:, content_type: } (preferred; matches the media
    #     shape Ai::Runner hands providers)
    #   - Hash { url: "https://..." } or { url: "data:<mime>;base64,..." }
    #   - String "data:<mime>;base64,..."
    #   - String raw base64 -- defaults to image/jpeg
    def call(image:)
      data_url = normalize_image(image)
      return Result.new(ok: false, error: "missing_image") unless data_url

      raw = call_vlm!(data_url: data_url)
      content = raw.dig("choices", 0, "message", "content").to_s
      parsed = parse_json(content)

      unless parsed.is_a?(Hash)
        return Result.new(ok: false, error: "non_json_response", raw: raw)
      end

      Result.new(
        ok: true,
        people_count: normalize_count(parsed["people_count"]),
        descriptions: normalize_descriptions(parsed["descriptions"]),
        prominent_roles: normalize_strings(parsed["prominent_roles"], cap: 8),
        scene: parsed["scene"].to_s.presence,
        raw: raw
      )
    rescue Ai::NvidiaClient::AuthError => e
      Result.new(ok: false, error: "auth:#{e.message[0, 160]}")
    rescue Ai::NvidiaClient::RateLimitError => e
      Result.new(ok: false, error: "rate_limited:#{e.message[0, 160]}")
    rescue StandardError => e
      Result.new(ok: false, error: "#{e.class}:#{e.message[0, 160]}")
    end

    private

    def provider
      @provider ||= Ai::ProviderRegistry.build_provider("nvidia")
    end

    def call_vlm!(data_url:)
      provider.chat!(
        role: @role,
        messages: [
          { role: "system", content: system_prompt },
          { role: "user", content: [
            { type: "text", text: user_prompt },
            { type: "image_url", image_url: { url: data_url } }
          ] }
        ],
        temperature: @temperature,
        max_tokens: @max_tokens,
        response_format: { "type" => "json_object" }
      )
    rescue Ai::NvidiaModelRouter::UnconfiguredRoleError
      # Primary role unreachable; walk the fallback list.
      @fallback_roles.each do |fallback|
        begin
          return try_role!(role: fallback, data_url: data_url)
        rescue Ai::NvidiaModelRouter::UnconfiguredRoleError
          next
        end
      end
      raise
    end

    def try_role!(role:, data_url:)
      row = Ai::NvidiaModelRouter.resolve!(role)
      Ai::NvidiaClient.new(setting: row, rate_limiter: Ai::NvidiaRateLimiter.new)
                      .chat!(
                        model: row.effective_model,
                        messages: [
                          { role: "system", content: system_prompt },
                          { role: "user", content: [
                            { type: "text", text: user_prompt },
                            { type: "image_url", image_url: { url: data_url } }
                          ] }
                        ],
                        temperature: @temperature,
                        max_tokens: @max_tokens,
                        response_format: { "type" => "json_object" }
                      )
    end

    def system_prompt
      <<~SYS.strip
        You are an image analyst describing the people visible in a single image.

        Return ONLY a JSON object matching this schema -- no prose, no markdown:
        {
          "people_count": integer (>= 0; 0 when no human figures are visible),
          "descriptions": [
            {
              "index": integer (0-based),
              "role": string,               // e.g. "primary_subject", "companion", "crowd"
              "appearance": string,         // 1-2 short sentences
              "position": string,           // "foreground"|"midground"|"background"|"left"|"right"|...
              "expression": string          // optional, "smiling", "serious", ""
            }
          ],
          "prominent_roles": [string],       // short tag set, e.g. ["creator", "partner"]
          "scene": string                    // one-line scene summary, e.g. "rooftop dinner"
        }

        Be conservative: do not invent people who are not clearly visible. Cap people_count at 30 for dense crowds.
      SYS
    end

    def user_prompt
      "Describe the people in this image per the schema. Return JSON only."
    end

    def normalize_image(image)
      case image
      when Hash
        if image[:url].present? || image["url"].present?
          image[:url].presence || image["url"]
        else
          bytes = image[:bytes] || image["bytes"]
          return nil if bytes.blank?

          mime = image[:content_type].presence || image["content_type"].presence || "image/jpeg"
          Ai::NvidiaClient.image_data_url(bytes: bytes, mime_type: mime)
        end
      when String
        return image if image.start_with?("http://", "https://", "data:")

        return nil if image.blank?

        # Assume raw base64; default to image/jpeg.
        "data:image/jpeg;base64,#{image}"
      end
    end

    def parse_json(text)
      stripped = text.to_s.strip.sub(/\A```(?:json)?\s*/, "").sub(/\s*```\z/, "")
      return nil if stripped.empty?

      JSON.parse(stripped)
    rescue JSON::ParserError
      match = stripped[/\{.*\}/m]
      return nil unless match

      begin
        JSON.parse(match)
      rescue JSON::ParserError
        nil
      end
    end

    def normalize_count(value)
      (Integer(value) rescue 0).clamp(0, MAX_PEOPLE_CAP)
    end

    def normalize_descriptions(value)
      Array(value).filter_map.with_index do |item, i|
        next nil unless item.is_a?(Hash)

        appearance = item["appearance"].to_s.strip
        next nil if appearance.blank?

        {
          "index" => (Integer(item["index"]) rescue i),
          "role" => item["role"].to_s.strip.presence,
          "appearance" => appearance,
          "position" => item["position"].to_s.strip.presence,
          "expression" => item["expression"].to_s.strip.presence
        }.compact
      end.first(MAX_PEOPLE_CAP)
    end

    def normalize_strings(value, cap:)
      Array(value).filter_map { |v| v.to_s.strip.presence }.uniq.first(cap)
    end
  end
end
