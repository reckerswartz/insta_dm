# frozen_string_literal: true

require "digest"

module Ai
  class ProfileInsightStore
    STORE_KEY = "ai_signal_store"
    VERSION = "v1"
    MAX_SIGNAL_ITEMS = 40
    MAX_HISTORY_ITEMS = 30
    MAX_PROCESSED_SOURCES = 200

    def ingest_post!(profile:, post:, analysis:, metadata:)
      return unless profile && post

      analysis_hash = normalize_hash(analysis)
      metadata_hash = normalize_hash(metadata)
      source_key = "post:#{post.id}"
      source_signature = Digest::SHA256.hexdigest({ analysis: analysis_hash, metadata: metadata_hash }.to_json)

      with_behavior_profile(profile) do |record|
        store = normalized_store(record.metadata)
        return record if processed_source_unchanged?(store: store, source_key: source_key, signature: source_signature)

        upsert_signal!(store: store, bucket: "topics", values: analysis_hash["topics"], source: source_key)
        upsert_signal!(store: store, bucket: "interests", values: analysis_hash["hashtags"], source: source_key)
        upsert_signal!(store: store, bucket: "interests", values: analysis_hash["mentions"], source: source_key)
        upsert_signal!(store: store, bucket: "lifestyle", values: extract_lifestyle_signals(analysis_hash), source: source_key)
        upsert_signal!(store: store, bucket: "communication_style", values: extract_style_signals(analysis_hash), source: source_key)

        engagement_score = normalize_float(post.likes_count.to_f * 0.1 + post.comments_count.to_f * 0.6)
        append_history!(
          store: store,
          type: "post",
          source: source_key,
          summary: analysis_hash["image_description"].to_s,
          topics: normalize_string_array(analysis_hash["topics"]),
          engagement_score: engagement_score
        )

        mark_processed_source!(store: store, source_key: source_key, signature: source_signature)
        persist_store!(record: record, store: store)
      end
    rescue StandardError
      nil
    end

    def ingest_story!(profile:, event:, intelligence:)
      return unless profile && event

      payload = normalize_hash(intelligence)
      source_key = "story_event:#{event.id}"
      source_signature = Digest::SHA256.hexdigest(payload.to_json)

      with_behavior_profile(profile) do |record|
        store = normalized_store(record.metadata)
        return record if processed_source_unchanged?(store: store, source_key: source_key, signature: source_signature)

        upsert_signal!(store: store, bucket: "topics", values: payload["topics"], source: source_key)
        upsert_signal!(store: store, bucket: "interests", values: payload["hashtags"], source: source_key)
        upsert_signal!(store: store, bucket: "interests", values: payload["mentions"], source: source_key)
        upsert_signal!(store: store, bucket: "lifestyle", values: extract_story_lifestyle_signals(payload), source: source_key)

        append_history!(
          store: store,
          type: "story",
          source: source_key,
          summary: payload["ocr_text"].to_s.presence || payload["transcript"].to_s,
          topics: normalize_string_array(payload["topics"]),
          engagement_score: nil
        )

        mark_processed_source!(store: store, source_key: source_key, signature: source_signature)
        persist_store!(record: record, store: store)
      end
    rescue StandardError
      nil
    end

    private

    def with_behavior_profile(profile)
      profile.with_lock do
        profile.reload
        record = profile.instagram_profile_behavior_profile || profile.build_instagram_profile_behavior_profile
        yield(record)
      end
    end

    def normalized_store(metadata)
      data = metadata.is_a?(Hash) ? metadata.deep_dup : {}
      store = data[STORE_KEY]
      store = {} unless store.is_a?(Hash)

      store["version"] = VERSION
      store["signals"] = store["signals"].is_a?(Hash) ? store["signals"] : {}
      store["history"] = Array(store["history"]).first(MAX_HISTORY_ITEMS)
      store["processed_sources"] = store["processed_sources"].is_a?(Hash) ? store["processed_sources"] : {}
      store["updated_at"] = Time.current.iso8601(3)
      store
    end

    def processed_source_unchanged?(store:, source_key:, signature:)
      processed = store["processed_sources"].is_a?(Hash) ? store["processed_sources"] : {}
      processed[source_key].to_s == signature.to_s
    end

    def mark_processed_source!(store:, source_key:, signature:)
      processed = store["processed_sources"].is_a?(Hash) ? store["processed_sources"] : {}
      processed[source_key] = signature.to_s
      if processed.size > MAX_PROCESSED_SOURCES
        trim = processed.to_a.last(MAX_PROCESSED_SOURCES).to_h
        store["processed_sources"] = trim
      else
        store["processed_sources"] = processed
      end
    end

    def upsert_signal!(store:, bucket:, values:, source:)
      bucket_key = bucket.to_s
      signals = store["signals"].is_a?(Hash) ? store["signals"] : {}
      rows = Array(signals[bucket_key]).select { |row| row.is_a?(Hash) }

      index = rows.each_with_object({}) do |row, memo|
        token = row["value"].to_s
        memo[token] = row if token.present?
      end

      normalize_string_array(values).first(30).each do |value|
        row = index[value] || { "value" => value, "count" => 0, "first_seen_at" => Time.current.iso8601(3) }
        row["count"] = row["count"].to_i + 1
        row["last_seen_at"] = Time.current.iso8601(3)
        row["sources"] = (Array(row["sources"]).map(&:to_s) << source.to_s).uniq.last(8)
        index[value] = row
      end

      signals[bucket_key] = index.values.sort_by { |row| -row["count"].to_i }.first(MAX_SIGNAL_ITEMS)
      store["signals"] = signals
    end

    def append_history!(store:, type:, source:, summary:, topics:, engagement_score:)
      history = Array(store["history"]).select { |row| row.is_a?(Hash) }
      history << {
        "type" => type.to_s,
        "source" => source.to_s,
        "summary" => summary.to_s.byteslice(0, 260),
        "topics" => normalize_string_array(topics).first(8),
        "engagement_score" => engagement_score,
        "captured_at" => Time.current.iso8601(3)
      }
      store["history"] = history.last(MAX_HISTORY_ITEMS)
    end

    def persist_store!(record:, store:)
      metadata = record.metadata.is_a?(Hash) ? record.metadata.deep_dup : {}
      metadata[STORE_KEY] = store
      record.metadata = metadata
      record.activity_score = [record.activity_score.to_f, computed_signal_density(store)].max.round(4)
      record.save!
      record
    end

    def computed_signal_density(store)
      signals = store["signals"].is_a?(Hash) ? store["signals"] : {}
      total = signals.values.sum { |rows| Array(rows).sum { |row| row["count"].to_i } }
      [total.to_f / 120.0, 1.0].min
    end

    def extract_lifestyle_signals(analysis)
      data = [analysis["topics"], analysis["hashtags"], analysis["image_description"]].flatten.compact.join(" ").downcase
      signals = []
      signals << "travel" if data.match?(/\b(travel|trip|vacation|beach|airport|hotel|mountain|city)\b/)
      signals << "fitness" if data.match?(/\b(workout|gym|run|fitness|training|yoga|sport)\b/)
      signals << "food" if data.match?(/\b(food|dinner|brunch|coffee|restaurant|cafe|meal)\b/)
      signals << "celebration" if data.match?(/\b(birthday|wedding|party|anniversary|graduation|celebration)\b/)
      signals << "fashion" if data.match?(/\b(outfit|style|fashion|lookbook)\b/)
      signals
    end

    def extract_story_lifestyle_signals(payload)
      data = [payload["topics"], payload["hashtags"], payload["ocr_text"], payload["transcript"]].flatten.compact.join(" ").downcase
      signals = []
      signals << "travel" if data.match?(/\b(travel|trip|vacation|airport|hotel|beach)\b/)
      signals << "fitness" if data.match?(/\b(workout|gym|run|training|fitness)\b/)
      signals << "social" if data.match?(/\b(friend|family|crew|together|hangout|party)\b/)
      signals << "lifestyle" if signals.empty?
      signals
    end

    def extract_style_signals(analysis)
      description = analysis["image_description"].to_s.downcase
      style = []
      style << "energetic" if description.match?(/\b(energy|dynamic|action|movement)\b/)
      style << "calm" if description.match?(/\b(calm|quiet|soft|minimal)\b/)
      style << "creative" if description.match?(/\b(art|design|music|creative|studio)\b/)
      style
    end

    def normalize_hash(value)
      value.is_a?(Hash) ? value.deep_dup : {}
    end

    def normalize_string_array(value)
      Array(value).filter_map do |entry|
        token = entry.to_s.downcase.strip
        next if token.blank?
        next if noise_token?(token)

        token.byteslice(0, 60)
      end.uniq
    end

    def normalize_float(value)
      return nil unless value.is_a?(Numeric)

      value.round(4)
    end

    def noise_token?(token)
      return true if token.match?(/\A\d+\z/)
      return true if token.match?(/(error|timeout|exception|stacktrace|failed|unavailable)/i)
      return true if token.length < 2

      false
    end
  end
end
