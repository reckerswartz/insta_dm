module InstagramAccounts
  class StoryArchiveQuery
    DEFAULT_PER_PAGE = 12
    MIN_PER_PAGE = 8
    MAX_PER_PAGE = 40
    ALLOWED_STATUS_FILTERS = %w[not_requested queued running completed failed skipped].freeze

    Result = Struct.new(:events, :page, :per_page, :total, :has_more, :on, keyword_init: true)

    STALE_COMMENT_JOB_MESSAGE = "Previous generation job appears stalled. Please retry.".freeze
    STALE_ANALYSIS_JOB_MESSAGE = "Previous story analysis job appears stalled or missing.".freeze

    def initialize(
      account:,
      page:,
      per_page:,
      on: nil,
      status: nil,
      reason_code: nil,
      queue_inspector: LlmQueueInspector.new,
      analysis_queue_inspector: StoryAnalysisQueueInspector.new
    )
      @account = account
      @page = page.to_i
      @per_page = per_page.to_i
      @raw_on = on
      @raw_status = status
      @raw_reason_code = reason_code
      @queue_inspector = queue_inspector
      @analysis_queue_inspector = analysis_queue_inspector
    end

    def call
      parsed_on = parse_archive_date(raw_on)
      parsed_status = normalize_status(raw_status)
      parsed_reason_code = normalize_reason_code(raw_reason_code)
      normalized_page = [page, 1].max
      normalized_per_page = normalize_per_page

      scoped = base_scope
      scoped = scoped.where(
        "DATE(COALESCE(instagram_profile_events.occurred_at, instagram_profile_events.detected_at, instagram_profile_events.created_at)) = ?",
        parsed_on
      ) if parsed_on
      scoped = scoped.where(llm_comment_status: parsed_status) if parsed_status.present?
      scoped = scoped.where(reason_code_filter_sql, parsed_reason_code) if parsed_reason_code.present?
      scoped = scoped.order(detected_at: :desc, id: :desc)

      total = scoped.count
      events = scoped.offset((normalized_page - 1) * normalized_per_page).limit(normalized_per_page).to_a
      normalize_stale_llm_comment_states!(events)
      normalize_story_analysis_queue_states!(events)

      Result.new(
        events: events,
        page: normalized_page,
        per_page: normalized_per_page,
        total: total,
        has_more: (normalized_page * normalized_per_page) < total,
        on: parsed_on
      )
    end

    private

    attr_reader :account, :page, :per_page, :raw_on, :raw_status, :raw_reason_code, :queue_inspector, :analysis_queue_inspector

    def base_scope
      InstagramProfileEvent
        .joins(:instagram_profile)
        .joins(:media_attachment)
        .includes(:instagram_profile)
        .with_attached_media
        .with_attached_preview_image
        .where(
          instagram_profiles: { instagram_account_id: account.id },
          kind: InstagramProfileEvent::STORY_ARCHIVE_EVENT_KINDS
        )
    end

    def normalize_per_page
      value = per_page
      value = DEFAULT_PER_PAGE if value <= 0
      value.clamp(MIN_PER_PAGE, MAX_PER_PAGE)
    end

    def parse_archive_date(raw)
      value = raw.to_s.strip
      return nil if value.blank?

      Date.iso8601(value)
    rescue StandardError
      nil
    end

    def normalize_status(raw)
      value = raw.to_s.strip.downcase
      return nil if value.blank?

      ALLOWED_STATUS_FILTERS.include?(value) ? value : nil
    rescue StandardError
      nil
    end

    def normalize_reason_code(raw)
      value = raw.to_s.strip.downcase
      return nil if value.blank?

      sanitized = value.gsub(/[^a-z0-9_.:-]/, "")
      sanitized.presence
    rescue StandardError
      nil
    end

    def reason_code_filter_sql
      <<~SQL.squish
        LOWER(
          COALESCE(
            instagram_profile_events.llm_comment_metadata -> 'last_failure' ->> 'reason',
            instagram_profile_events.llm_comment_metadata -> 'generation_policy' ->> 'reason_code',
            instagram_profile_events.llm_comment_metadata -> 'verified_story_policy' ->> 'reason_code',
            instagram_profile_events.metadata -> 'validated_story_insights' -> 'generation_policy' ->> 'reason_code',
            instagram_profile_events.metadata -> 'story_generation_policy' ->> 'reason_code'
          )
        ) = ?
      SQL
    end

    def normalize_stale_llm_comment_states!(events)
      Array(events).each do |event|
        next unless event.llm_comment_in_progress?
        next unless queue_inspector.stale_comment_job?(event: event)

        event.update_columns(
          llm_comment_status: "failed",
          llm_comment_last_error: STALE_COMMENT_JOB_MESSAGE,
          updated_at: Time.current
        )
        event.llm_comment_status = "failed"
        event.llm_comment_last_error = STALE_COMMENT_JOB_MESSAGE
      rescue StandardError
        next
      end
    end

    def normalize_story_analysis_queue_states!(events)
      rows = Array(events).filter_map do |event|
        metadata = event.metadata.is_a?(Hash) ? event.metadata : {}
        story_id = metadata["story_id"].to_s.strip
        next if story_id.blank?

        {
          profile_id: event.instagram_profile_id.to_i,
          story_id: story_id,
          queue_external_id: "story_analysis_queued:#{story_id}"
        }
      end
      return if rows.empty?

      profile_ids = rows.map { |row| row[:profile_id] }.uniq
      story_ids = rows.map { |row| row[:story_id] }.uniq
      external_ids = rows.map { |row| row[:queue_external_id] }.uniq

      queue_events_by_key = InstagramProfileEvent
        .where(
          kind: "story_analysis_queued",
          instagram_profile_id: profile_ids,
          external_id: external_ids
        )
        .index_by do |queue_event|
          queue_metadata = queue_event.metadata.is_a?(Hash) ? queue_event.metadata : {}
          queue_story_id = queue_metadata["story_id"].to_s.presence || queue_event.external_id.to_s.delete_prefix("story_analysis_queued:")
          story_key(profile_id: queue_event.instagram_profile_id, story_id: queue_story_id)
        end

      analyzed_keys = InstagramProfileEvent
        .where(kind: "story_analyzed", instagram_profile_id: profile_ids)
        .where("metadata ->> 'story_id' IN (?)", story_ids)
        .pluck(:instagram_profile_id, Arel.sql("metadata ->> 'story_id'"))
        .each_with_object({}) do |(profile_id, story_id), memo|
          memo[story_key(profile_id: profile_id, story_id: story_id)] = true
        end

      now = Time.current
      rows.each do |row|
        key = story_key(profile_id: row[:profile_id], story_id: row[:story_id])
        queue_event = queue_events_by_key[key]
        next unless queue_event

        metadata = queue_event.metadata.is_a?(Hash) ? queue_event.metadata.deep_dup : {}
        status = metadata["status"].to_s
        next if status.in?(%w[completed failed])

        if analyzed_keys[key]
          metadata["status"] = "completed"
          metadata["status_reason"] ||= "analysis_event_recorded"
          metadata["completed_at"] ||= now.iso8601(3)
          metadata["status_updated_at"] = now.iso8601(3)
          queue_event.update_columns(metadata: metadata, updated_at: now)
          next
        end

        next unless analysis_queue_inspector.stale_job?(event: queue_event)

        metadata["status"] = "failed"
        metadata["status_reason"] = "stale_or_missing_job"
        metadata["failure_reason"] = "stale_or_missing_job"
        metadata["failed_at"] = now.iso8601(3)
        metadata["status_updated_at"] = now.iso8601(3)
        metadata["error_message"] = STALE_ANALYSIS_JOB_MESSAGE
        queue_event.update_columns(metadata: metadata, updated_at: now)
      rescue StandardError
        next
      end
    rescue StandardError
      nil
    end

    def story_key(profile_id:, story_id:)
      "#{profile_id}:#{story_id}"
    end
  end
end
