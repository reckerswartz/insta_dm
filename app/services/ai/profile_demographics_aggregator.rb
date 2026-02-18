require "json"

module Ai
  class ProfileDemographicsAggregator
    DEFAULT_MODEL = "mistral:7b".freeze

    def initialize(account:, model: nil)
      @account = account
      @model = model.to_s.presence || DEFAULT_MODEL
    end

    def aggregate!(dataset:)
      response = call_aggregator_llm(dataset: dataset)
      normalized = normalize_result(response)
      return normalized if normalized[:ok]

      heuristic_fallback(dataset: dataset, error: normalized[:error])
    rescue StandardError => e
      heuristic_fallback(dataset: dataset, error: e.message)
    end

    private

    def call_aggregator_llm(dataset:)
      client = local_client
      return nil unless client

      prompt = build_prompt(dataset: dataset)
      resp = client.generate_text_json!(
        model: @model,
        prompt: prompt,
        temperature: 0.1,
        max_output_tokens: 1600,
        usage_category: "report_generation",
        usage_context: { workflow: "profile_demographics_aggregator" }
      )

      resp[:json].is_a?(Hash) ? resp[:json] : nil
    end

    def local_client
      Ai::LocalMicroserviceClient.new
    end

    def build_prompt(dataset:)
      <<~PROMPT
        You are an AI aggregation engine that consolidates structured JSON analyses over time.

        Task:
        - Combine profile-level and post-level analysis JSON.
        - Infer missing demographics cautiously: age, gender, location.
        - Prefer explicit self-declared evidence over weak assumptions.
        - Confidence must be 0.0 to 1.0.
        - If evidence is weak, return null with low confidence.

        Output STRICT JSON only with this schema:
        {
          "profile_inference": {
            "age": 0,
            "age_range": "",
            "age_confidence": 0.0,
            "gender": "",
            "gender_indicators": [],
            "gender_confidence": 0.0,
            "location": "",
            "location_signals": [],
            "location_confidence": 0.0,
            "evidence": "",
            "why": ""
          },
          "post_inferences": [
            {
              "shortcode": "",
              "source_type": "",
              "source_ref": "",
              "age": 0,
              "gender": "",
              "location": "",
              "confidence": 0.0,
              "evidence": "",
              "relevant": true
            }
          ]
        }

        INPUT_DATASET_JSON:
        #{JSON.pretty_generate(dataset)}
      PROMPT
    end

    def normalize_result(raw)
      return { ok: false, error: "aggregator_response_blank" } unless raw.is_a?(Hash)

      profile_raw = raw["profile_inference"].is_a?(Hash) ? raw["profile_inference"] : {}
      post_raw = Array(raw["post_inferences"]).select { |entry| entry.is_a?(Hash) }

      profile_inference = {
        age: integer_or_nil(profile_raw["age"]),
        age_range: clean_text(profile_raw["age_range"]),
        age_confidence: float_or_nil(profile_raw["age_confidence"]),
        gender: clean_text(profile_raw["gender"]),
        gender_indicators: Array(profile_raw["gender_indicators"]).map { |v| clean_text(v) }.compact.first(6),
        gender_confidence: float_or_nil(profile_raw["gender_confidence"]),
        location: clean_text(profile_raw["location"]),
        location_signals: Array(profile_raw["location_signals"]).map { |v| clean_text(v) }.compact.first(8),
        location_confidence: float_or_nil(profile_raw["location_confidence"]),
        evidence: clean_text(profile_raw["evidence"]),
        why: clean_text(profile_raw["why"])
      }

      post_inferences = post_raw.filter_map do |entry|
        shortcode = clean_text(entry["shortcode"])
        next if shortcode.blank?

        {
          shortcode: shortcode,
          source_type: clean_text(entry["source_type"]),
          source_ref: clean_text(entry["source_ref"]),
          age: integer_or_nil(entry["age"]),
          gender: clean_text(entry["gender"]),
          location: clean_text(entry["location"]),
          confidence: float_or_nil(entry["confidence"]),
          evidence: clean_text(entry["evidence"]),
          relevant: ActiveModel::Type::Boolean.new.cast(entry["relevant"])
        }
      end

      {
        ok: true,
        source: "json_aggregator_llm",
        profile_inference: profile_inference,
        post_inferences: post_inferences
      }
    end

    def heuristic_fallback(dataset:, error: nil)
      profile_demographics = Array(dataset.dig(:analysis_pool, :profile_demographics))
      post_demographics = Array(dataset.dig(:analysis_pool, :post_demographics))

      ages = profile_demographics.map { |d| integer_or_nil(d["age"] || d[:age]) }.compact
      genders = profile_demographics.map { |d| clean_text(d["gender"] || d[:gender]) }.reject(&:blank?)
      locations = profile_demographics.map { |d| clean_text(d["location"] || d[:location]) }.reject(&:blank?)

      ages.concat(post_demographics.map { |d| integer_or_nil(d["age"] || d[:age]) }.compact)
      genders.concat(post_demographics.map { |d| clean_text(d["gender"] || d[:gender]) }.reject(&:blank?))
      locations.concat(post_demographics.map { |d| clean_text(d["location"] || d[:location]) }.reject(&:blank?))

      profile_inference = {
        age: median(ages),
        age_range: ages.any? ? "#{ages.min}-#{ages.max}" : nil,
        age_confidence: confidence_from_count(ages.length),
        gender: mode(genders),
        gender_indicators: genders.group_by(&:itself).sort_by { |_value, bucket| -bucket.length }.first(4).map(&:first),
        gender_confidence: confidence_from_count(genders.length),
        location: mode(locations),
        location_signals: locations.group_by(&:itself).sort_by { |_value, bucket| -bucket.length }.first(5).map(&:first),
        location_confidence: confidence_from_count(locations.length),
        evidence: "Heuristic consolidation from accumulated analysis JSON.",
        why: error.to_s.presence
      }

      {
        ok: true,
        source: "heuristic_fallback",
        profile_inference: profile_inference,
        post_inferences: [],
        error: error.to_s.presence
      }
    end

    def integer_or_nil(value)
      return nil if value.blank?
      Integer(value)
    rescue StandardError
      nil
    end

    def float_or_nil(value)
      return nil if value.blank?
      Float(value).clamp(0.0, 1.0)
    rescue StandardError
      nil
    end

    def clean_text(value)
      text = value.to_s.strip
      text.presence
    end

    def mode(values)
      arr = Array(values).reject(&:blank?)
      return nil if arr.empty?

      arr.group_by(&:itself).max_by { |_v, bucket| bucket.length }&.first
    end

    def median(values)
      arr = Array(values).compact.sort
      return nil if arr.empty?

      mid = arr.length / 2
      return arr[mid] if arr.length.odd?

      ((arr[mid - 1] + arr[mid]) / 2.0).round
    end

    def confidence_from_count(count)
      return nil if count.to_i <= 0

      [0.25 + (count.to_i * 0.1), 0.8].min.round(2)
    end
  end
end
