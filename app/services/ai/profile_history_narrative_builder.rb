module Ai
  class ProfileHistoryNarrativeBuilder
    CHUNK_WORD_LIMIT = 500

    INTERESTING_EVENT_KINDS = %w[
      story_uploaded
      story_viewed
      story_downloaded
      story_analyzed
      story_reply_sent
      story_reply_skipped
      story_ad_skipped
      story_video_skipped
      story_sync_failed
      feed_post_image_downloaded
      feed_post_comment_posted
      post_comment_sent
      profile_details_refreshed
      avatar_downloaded
    ].freeze

    def self.append_event!(event)
      new(event: event).append_event!
    end

    def initialize(event:)
      @event = event
      @profile = event.instagram_profile
      @account = @profile&.instagram_account
    end

    def append_event!
      return unless @profile && @account
      return unless INTERESTING_EVENT_KINDS.include?(@event.kind.to_s)

      entry = summarize_event(@event)
      return if entry.blank?

      ts = @event.occurred_at || @event.detected_at || Time.current
      with_profile_lock do
        chunk = current_or_new_chunk!(entry: entry, timestamp: ts)
        content = chunk.content.to_s
        content = [content, entry].reject(&:blank?).join("\n")
        chunk.update!(
          content: content,
          word_count: words_in(content),
          entry_count: chunk.entry_count.to_i + 1,
          starts_at: chunk.starts_at || ts,
          ends_at: ts
        )
      end
    rescue StandardError => e
      Rails.logger.warn("[Ai::ProfileHistoryNarrativeBuilder] failed for profile_id=#{@profile&.id}: #{e.class}: #{e.message}")
      nil
    end

    private

    def summarize_event(event)
      metadata = event.metadata.is_a?(Hash) ? event.metadata : {}
      timestamp = (event.occurred_at || event.detected_at || Time.current).in_time_zone.strftime("%Y-%m-%d %H:%M")
      base = "[#{timestamp}] #{human_event_title(event.kind)}"

      details = []
      details << "story_id=#{metadata['story_id']}" if metadata['story_id'].to_s.present?
      details << "media=#{metadata['media_type']}" if metadata['media_type'].to_s.present?
      details << "location=#{metadata['location']}" if metadata['location'].to_s.present?
      details << "event=#{metadata['event']}" if metadata['event'].to_s.present?
      details << "description=#{normalize_text(metadata['ai_image_description'])}" if metadata['ai_image_description'].to_s.present?
      details << "caption=#{normalize_text(metadata['caption'])}" if metadata['caption'].to_s.present?
      details << "comment=#{normalize_text(metadata['ai_reply_text'] || metadata['comment_text'])}" if (metadata['ai_reply_text'].to_s.present? || metadata['comment_text'].to_s.present?)
      details << "reason=#{normalize_text(metadata['reason'] || metadata['skip_reason'])}" if (metadata['reason'].to_s.present? || metadata['skip_reason'].to_s.present?)
      details << "url=#{metadata['story_url']}" if metadata['story_url'].to_s.present?
      details << "permalink=#{metadata['permalink']}" if metadata['permalink'].to_s.present?

      line = [base, details.join(" | ")].reject(&:blank?).join(" - ")
      line.byteslice(0, 900)
    end

    def human_event_title(kind)
      kind.to_s.tr("_", " ").split.map(&:capitalize).join(" ")
    end

    def normalize_text(value)
      value.to_s.gsub(/\s+/, " ").strip.byteslice(0, 220)
    end

    def current_or_new_chunk!(entry:, timestamp:)
      needed = words_in(entry)
      current = @profile.instagram_profile_history_chunks.recent_first.first
      return create_chunk!(sequence: 1, timestamp: timestamp) unless current

      projected = current.word_count.to_i + needed
      return current if projected <= CHUNK_WORD_LIMIT

      create_chunk!(sequence: current.sequence.to_i + 1, timestamp: timestamp)
    end

    def create_chunk!(sequence:, timestamp:)
      @profile.instagram_profile_history_chunks.create!(
        instagram_account: @account,
        sequence: sequence,
        content: "",
        word_count: 0,
        entry_count: 0,
        starts_at: timestamp,
        ends_at: timestamp,
        metadata: { source: "event_narrative_builder", chunk_word_limit: CHUNK_WORD_LIMIT }
      )
    end

    def words_in(text)
      text.to_s.scan(/\b[^\s]+\b/).length
    end

    def with_profile_lock(&block)
      @profile.with_lock(&block)
    end
  end
end
