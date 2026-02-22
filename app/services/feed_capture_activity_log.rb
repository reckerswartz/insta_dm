require "securerandom"

class FeedCaptureActivityLog
  CACHE_TTL = 36.hours
  MAX_ENTRIES = 80
  DEFAULT_LIMIT = 25

  class << self
    def clear!(account: nil)
      if account.present?
        storage_cache.delete(cache_key(account.id))
      elsif storage_cache.respond_to?(:clear)
        storage_cache.clear
      end
      nil
    rescue StandardError
      nil
    end

    def append!(account:, status:, message:, source: nil, broadcast: true)
      return nil if account.blank?

      normalized_message = message.to_s.strip
      return nil if normalized_message.blank?

      entry = {
        id: SecureRandom.hex(10),
        occurred_at: Time.current,
        status: normalize_status(status),
        source: source.to_s.presence,
        message: normalized_message.byteslice(0, 420)
      }

      entries = [ entry ] + entries_for(account: account, limit: MAX_ENTRIES)
      entries = entries.first(MAX_ENTRIES)
      persist_entries(account: account, entries: entries)
      broadcast_section(account: account, entries: entries.first(DEFAULT_LIMIT)) if broadcast
      entry
    rescue StandardError => e
      Rails.logger.warn("[FeedCaptureActivityLog] append failed for account_id=#{account&.id}: #{e.class}: #{e.message}")
      nil
    end

    def entries_for(account:, limit: DEFAULT_LIMIT)
      return [] if account.blank?

      cap = limit.to_i.clamp(1, MAX_ENTRIES)
      raw_entries = Array(storage_cache.read(cache_key(account.id)))
      raw_entries.filter_map { |raw| normalize_entry(raw) }.first(cap)
    rescue StandardError
      []
    end

    def broadcast_section(account:, entries: nil)
      return nil if account.blank?

      Turbo::StreamsChannel.broadcast_replace_to(
        account,
        target: "feed_capture_activity_section",
        partial: "instagram_accounts/feed_capture_activity_section",
        locals: {
          account: account,
          feed_capture_activity_entries: Array(entries || entries_for(account: account, limit: DEFAULT_LIMIT))
        }
      )
    rescue StandardError => e
      Rails.logger.warn("[FeedCaptureActivityLog] broadcast failed for account_id=#{account&.id}: #{e.class}: #{e.message}")
      nil
    end

    private

    def persist_entries(account:, entries:)
      payload = entries.first(MAX_ENTRIES).map do |entry|
        {
          "id" => entry[:id].to_s,
          "occurred_at" => entry[:occurred_at].is_a?(Time) ? entry[:occurred_at].iso8601(3) : Time.current.iso8601(3),
          "status" => normalize_status(entry[:status]),
          "source" => entry[:source].to_s.presence,
          "message" => entry[:message].to_s.byteslice(0, 420)
        }
      end

      storage_cache.write(cache_key(account.id), payload, expires_in: CACHE_TTL)
    end

    def normalize_entry(raw)
      hash = raw.is_a?(Hash) ? raw : {}
      message = value_for(hash, :message).to_s.strip
      return nil if message.blank?

      {
        id: value_for(hash, :id).to_s.presence || SecureRandom.hex(6),
        occurred_at: parse_time(value_for(hash, :occurred_at)),
        status: normalize_status(value_for(hash, :status)),
        source: value_for(hash, :source).to_s.presence,
        message: message.byteslice(0, 420)
      }
    end

    def parse_time(value)
      return value if value.is_a?(Time)

      parsed = Time.zone.parse(value.to_s)
      parsed || Time.current
    rescue StandardError
      Time.current
    end

    def normalize_status(value)
      raw = value.to_s.strip.downcase
      return "failed" if raw.in?(%w[failed error])
      return "succeeded" if raw.in?(%w[succeeded success completed complete])
      return "running" if raw.in?(%w[running in_progress active])
      return "queued" if raw.in?(%w[queued pending enqueued])
      return "skipped" if raw == "skipped"

      "info"
    end

    def cache_key(account_id)
      "feed_capture_activity:#{account_id.to_i}"
    end

    def value_for(hash, key)
      hash[key] || hash[key.to_s]
    end

    def storage_cache
      return Rails.cache unless Rails.cache.is_a?(ActiveSupport::Cache::NullStore)

      @fallback_cache ||= ActiveSupport::Cache::MemoryStore.new(expires_in: CACHE_TTL)
    end
  end
end
