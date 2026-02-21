module InstagramAccounts
  class SkipDiagnosticsService
    VALID_REASONS = %w[
      profile_not_in_network
      duplicate_story_already_replied
      duplicate_story_already_downloaded
      invalid_story_media
      story_page_unavailable
      replies_not_allowed
      reply_unavailable
      interaction_retry_window_active
      missing_auto_reply_tag
      external_profile_link_detected
      story_feed_media_external
      api_can_reply_false
      already_processed
    ].freeze

    RECOVERABLE_REASONS = %w[
      api_story_media_unavailable
      story_id_unresolved
      next_navigation_failed
      loop_exited_without_story_processing
      rate_limited
      transient_network_error
      media_download_failed
      story_context_missing
      story_context_missing_after_view_gate
      story_view_gate_not_cleared
      story_processing_failed
    ].freeze

    REVIEW_REASONS = %w[
      reply_box_not_found
      comment_submit_failed
      next_navigation_failed
      story_context_missing
      reply_precheck_error
      missing_media_url
      media_download_or_validation_failed
      session_or_cookie_invalid
    ].freeze

    def initialize(account:, hours:)
      @account = account
      @hours = hours.to_i
    end

    def call
      scope = base_scope
      reason_rows = Hash.new(0)

      scope.limit(5_000).each do |event|
        metadata = event.metadata.is_a?(Hash) ? event.metadata : {}
        reason = metadata["reason"].to_s.presence || event.kind.to_s.presence || "unknown"
        reason_rows[reason] += 1
      end

      {
        window_hours: hours,
        total: scope.count,
        by_reason: build_reasons(reason_rows)
      }
    rescue StandardError
      { window_hours: hours, total: 0, by_reason: [] }
    end

    private

    attr_reader :account, :hours

    def base_scope
      InstagramProfileEvent
        .joins(:instagram_profile)
        .where(instagram_profiles: { instagram_account_id: account.id })
        .where(kind: %w[story_reply_skipped story_sync_failed story_ad_skipped])
        .where("detected_at >= ?", hours.hours.ago)
    end

    def build_reasons(reason_rows)
      reason_rows
        .sort_by { |_reason, count| -count }
        .map do |reason, count|
          {
            reason: reason,
            count: count.to_i,
            classification: classification_for(reason),
            retry_recommended: retry_recommended?(reason),
            action_hint: action_hint_for(reason)
          }
        end
    end

    def classification_for(reason)
      return "valid" if VALID_REASONS.include?(reason)
      return "recoverable" if RECOVERABLE_REASONS.include?(reason)
      return "review" if REVIEW_REASONS.include?(reason)
      return "valid" if reason.include?("ad") || reason.include?("sponsored")
      return "recoverable" if reason.include?("rate_limit") || reason.include?("429")
      return "valid" if reason.include?("duplicate") || reason.include?("already_")

      "review"
    end

    def retry_recommended?(reason)
      classification_for(reason) == "recoverable"
    end

    def action_hint_for(reason)
      case classification_for(reason)
      when "valid"
        "No action needed."
      when "recoverable"
        "Retry after cooldown and verify session/API limits or transport errors."
      else
        "Review task captures and Story sync metadata."
      end
    end
  end
end
