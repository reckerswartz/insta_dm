# frozen_string_literal: true

module Ai
  class ContextSignalScorer
    CACHE_TTL = 12.minutes

    def initialize(profile:, channel: "post")
      @profile = profile
      @channel = channel.to_s
    end

    def build(current_topics:, image_description:, caption: nil, limit: 12)
      baseline = cached_baseline
      query_tokens = normalize_tokens([ current_topics, image_description, caption ].flatten.compact.join(" "))

      scored = baseline[:signals].map do |row|
        value_tokens = normalize_tokens(row[:value])
        overlap = (value_tokens & query_tokens).length
        overlap_boost = overlap.positive? ? (0.75 + (overlap * 0.2)) : 0.0
        recency_boost = recency_weight(row[:last_seen_at])

        score = row[:base_score].to_f + overlap_boost + recency_boost
        row.merge(score: score.round(4), overlap_tokens: overlap)
      end

      prioritized = deduplicate_by_value(scored).sort_by { |row| -row[:score].to_f }.first(limit.to_i.clamp(4, 20))

      {
        prioritized_signals: prioritized.map do |row|
          {
            value: row[:value],
            signal_type: row[:signal_type],
            source: row[:source],
            score: row[:score],
            overlap_tokens: row[:overlap_tokens],
            count: row[:count],
            last_seen_at: row[:last_seen_at]
          }
        end,
        style_profile: baseline[:style_profile],
        engagement_memory: baseline[:engagement_memory],
        context_keywords: (
          prioritized.flat_map { |row| normalize_tokens(row[:value]) } +
          query_tokens
        ).uniq.first(40)
      }
    rescue StandardError
      {
        prioritized_signals: [],
        style_profile: {},
        engagement_memory: {},
        context_keywords: []
      }
    end

    private

    attr_reader :profile, :channel

    def cached_baseline
      ensure_store_seeded!
      key = [
        "context_signal_scorer",
        profile.id,
        channel,
        profile.updated_at.to_i,
        profile.instagram_profile_behavior_profile&.updated_at&.to_i
      ].join(":")

      Rails.cache.fetch(key, expires_in: CACHE_TTL) { build_baseline }
    end

    def ensure_store_seeded!
      metadata = profile.instagram_profile_behavior_profile&.metadata
      existing_store = metadata.is_a?(Hash) ? metadata.dig("ai_signal_store") : nil
      return if existing_store.is_a?(Hash)

      store = Ai::ProfileInsightStore.new
      profile.instagram_profile_posts.where(ai_status: "analyzed").recent_first.limit(12).each do |post|
        store.ingest_post!(profile: profile, post: post, analysis: post.analysis, metadata: post.metadata)
      end

      profile.instagram_profile_events.recent_first.limit(12).each do |event|
        meta = event.metadata.is_a?(Hash) ? event.metadata : {}
        payload =
          if meta.dig("validated_story_insights", "verified_story_facts").is_a?(Hash)
            meta.dig("validated_story_insights", "verified_story_facts")
          elsif meta["local_story_intelligence"].is_a?(Hash)
            meta["local_story_intelligence"]
          else
            {}
          end
        next if payload.blank?

        store.ingest_story!(profile: profile, event: event, intelligence: payload)
      end
    rescue StandardError
      nil
    end

    def build_baseline
      signals = []
      store_signals = signals_from_store
      behavior_signals = signals_from_behavior_summary
      strategy_signals = signals_from_message_strategy
      engagement_signals = signals_from_engagement

      signals.concat(store_signals)
      signals.concat(behavior_signals)
      signals.concat(strategy_signals)
      signals.concat(engagement_signals)

      collapsed = collapse_signals(signals)

      {
        signals: collapsed,
        style_profile: style_profile,
        engagement_memory: engagement_memory(engagement_signals)
      }
    end

    def signals_from_store
      store = profile.instagram_profile_behavior_profile&.metadata
      data = store.is_a?(Hash) ? store.dig("ai_signal_store", "signals") : nil
      return [] unless data.is_a?(Hash)

      rows = []
      data.each do |bucket, items|
        Array(items).each do |item|
          next unless item.is_a?(Hash)

          value = item["value"].to_s.downcase.strip
          next if value.blank?

          rows << {
            value: value,
            signal_type: bucket.to_s,
            source: "store",
            count: item["count"].to_i,
            last_seen_at: item["last_seen_at"].to_s,
            base_score: 1.4 + (item["count"].to_f * 0.12)
          }
        end
      end

      rows
    end

    def signals_from_behavior_summary
      summary = profile.instagram_profile_behavior_profile&.behavioral_summary
      data = summary.is_a?(Hash) ? summary : {}
      rows = []

      append_hash_signals!(rows, hash: data["topic_clusters"], signal_type: "topics", source: "behavior", base_weight: 1.2)
      append_hash_signals!(rows, hash: data["content_categories"], signal_type: "interests", source: "behavior", base_weight: 1.0)
      append_hash_signals!(rows, hash: data["top_hashtags"], signal_type: "hashtags", source: "behavior", base_weight: 0.9)

      rows
    end

    def signals_from_message_strategy
      strategy = profile.instagram_profile_message_strategies.recent_first.first
      return [] unless strategy

      rows = []
      normalize_array(strategy.best_topics).each do |value|
        rows << { value: value, signal_type: "best_topics", source: "strategy", count: 1, last_seen_at: strategy.updated_at&.iso8601, base_score: 1.1 }
      end
      normalize_array(strategy.avoid_topics).each do |value|
        rows << { value: value, signal_type: "avoid_topics", source: "strategy", count: 1, last_seen_at: strategy.updated_at&.iso8601, base_score: -0.9 }
      end
      rows
    end

    def signals_from_engagement
      rows = []
      profile.instagram_profile_posts
        .where(ai_status: "analyzed")
        .recent_first
        .limit(25)
        .each do |post|
          engagement = (post.likes_count.to_f * 0.08) + (post.comments_count.to_f * 0.6)
          next if engagement <= 0

          topics = normalize_array((post.analysis.is_a?(Hash) ? post.analysis["topics"] : []))
          topics.each do |topic|
            rows << {
              value: topic,
              signal_type: "engagement_topic",
              source: "post_insight",
              count: 1,
              last_seen_at: post.taken_at&.iso8601 || post.updated_at&.iso8601,
              base_score: [ engagement / 8.0, 2.0 ].min
            }
          end
        end
      rows
    end

    def collapse_signals(rows)
      grouped = {}
      rows.each do |row|
        value = row[:value].to_s.downcase.strip
        next if value.blank?

        key = "#{row[:signal_type]}:#{value}"
        existing = grouped[key] || {
          value: value,
          signal_type: row[:signal_type].to_s,
          source: row[:source].to_s,
          count: 0,
          last_seen_at: nil,
          base_score: 0.0
        }

        existing[:count] += row[:count].to_i
        existing[:base_score] += row[:base_score].to_f
        existing[:last_seen_at] = newest_time(existing[:last_seen_at], row[:last_seen_at])
        grouped[key] = existing
      end

      grouped.values
    end

    def style_profile
      insight = profile.instagram_profile_insights.recent_first.first
      persona = PersonalizationEngine.new.build(profile: profile)

      {
        tone: insight&.tone.to_s.presence || persona[:tone],
        formality: insight&.formality.to_s.presence || "casual",
        emoji_style: insight&.emoji_usage.to_s.presence || persona[:emoji_style],
        engagement_style: insight&.engagement_style.to_s.presence || persona[:engagement_style],
        channel: channel
      }.compact
    end

    def engagement_memory(engagement_signals)
      top = engagement_signals
        .sort_by { |row| -row[:base_score].to_f }
        .first(8)
        .map { |row| row[:value] }
        .uniq

      recent_comments = profile.instagram_profile_events
        .where(kind: "post_comment_sent")
        .order(detected_at: :desc, id: :desc)
        .limit(12)
        .pluck(:metadata)
        .filter_map do |meta|
          row = meta.is_a?(Hash) ? meta : {}
          row["comment_text"].to_s.strip.presence
        end
        .first(10)

      {
        top_performing_topics: top,
        recent_generated_comments: recent_comments
      }
    rescue StandardError
      {
        top_performing_topics: [],
        recent_generated_comments: []
      }
    end

    def append_hash_signals!(rows, hash:, signal_type:, source:, base_weight:)
      return unless hash.is_a?(Hash)

      hash.each do |key, count|
        token = key.to_s.downcase.strip
        next if token.blank?

        rows << {
          value: token,
          signal_type: signal_type,
          source: source,
          count: count.to_i,
          last_seen_at: profile.instagram_profile_behavior_profile&.updated_at&.iso8601,
          base_score: base_weight.to_f + (count.to_f * 0.1)
        }
      end
    end

    def normalize_array(value)
      Array(value).filter_map do |entry|
        token = entry.to_s.downcase.strip
        next if token.blank?

        token.byteslice(0, 64)
      end.uniq
    end

    def normalize_tokens(value)
      value.to_s.downcase.scan(/[a-z0-9]+/).reject { |token| token.length < 3 }.uniq
    end

    def recency_weight(last_seen_at)
      return 0.0 if last_seen_at.blank?

      ts = Time.zone.parse(last_seen_at.to_s) rescue nil
      return 0.0 unless ts

      hours = ((Time.current - ts) / 1.hour).to_f
      return 0.6 if hours <= 24
      return 0.35 if hours <= 72
      return 0.15 if hours <= 168

      0.0
    end

    def newest_time(a, b)
      return b if a.blank?
      return a if b.blank?

      at = Time.zone.parse(a.to_s) rescue nil
      bt = Time.zone.parse(b.to_s) rescue nil
      return a if at && bt && at >= bt
      return b if at && bt

      a
    end

    def deduplicate_by_value(rows)
      index = {}
      rows.each do |row|
        value = row[:value].to_s
        next if value.blank?

        existing = index[value]
        if existing.nil? || row[:score].to_f > existing[:score].to_f
          index[value] = row
        end
      end
      index.values
    end
  end
end
