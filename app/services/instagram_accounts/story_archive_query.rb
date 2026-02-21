module InstagramAccounts
  class StoryArchiveQuery
    DEFAULT_PER_PAGE = 12
    MIN_PER_PAGE = 8
    MAX_PER_PAGE = 40

    Result = Struct.new(:events, :page, :per_page, :total, :has_more, :on, keyword_init: true)

    STALE_COMMENT_JOB_MESSAGE = "Previous generation job appears stalled. Please retry.".freeze

    def initialize(account:, page:, per_page:, on: nil, queue_inspector: LlmQueueInspector.new)
      @account = account
      @page = page.to_i
      @per_page = per_page.to_i
      @raw_on = on
      @queue_inspector = queue_inspector
    end

    def call
      parsed_on = parse_archive_date(raw_on)
      normalized_page = [page, 1].max
      normalized_per_page = normalize_per_page

      scoped = base_scope
      scoped = scoped.where(
        "DATE(COALESCE(instagram_profile_events.occurred_at, instagram_profile_events.detected_at, instagram_profile_events.created_at)) = ?",
        parsed_on
      ) if parsed_on
      scoped = scoped.order(detected_at: :desc, id: :desc)

      total = scoped.count
      events = scoped.offset((normalized_page - 1) * normalized_per_page).limit(normalized_per_page).to_a
      normalize_stale_llm_comment_states!(events)

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

    attr_reader :account, :page, :per_page, :raw_on, :queue_inspector

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
  end
end
