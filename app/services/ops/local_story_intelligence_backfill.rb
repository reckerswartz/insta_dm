require "timeout"

module Ops
  class LocalStoryIntelligenceBackfill
    DEFAULT_LIMIT = 100
    EVENT_TIMEOUT_SECONDS = 45

    def initialize(account_id: nil, limit: nil, enqueue_comments: false)
      @account_id = account_id.to_s.presence
      @limit = limit.to_i.positive? ? limit.to_i : DEFAULT_LIMIT
      @enqueue_comments = ActiveModel::Type::Boolean.new.cast(enqueue_comments)
    end

    def backfill!
      result = {
        scanned: 0,
        enriched: 0,
        empty: 0,
        queued: 0,
        errors: 0,
        reasons: Hash.new(0)
      }

      story_event_scope.each do |event|
        break if result[:scanned] >= @limit
        next unless event.media.attached?

        result[:scanned] += 1
        payload = with_event_timeout(event: event) { event.send(:local_story_intelligence_payload) }
        next unless payload.is_a?(Hash)

        if event.send(:local_story_intelligence_blank?, payload)
          result[:empty] += 1
          reason = payload[:reason].to_s.presence || "local_story_intelligence_blank"
          result[:reasons][reason] += 1
          next
        end

        event.send(:persist_local_story_intelligence!, payload)
        result[:enriched] += 1

        next unless @enqueue_comments
        next unless regeneration_candidate?(event)

        if enqueue_comment_job(event, requested_by: "local_story_intelligence_backfill")
          result[:queued] += 1
        end
      rescue StandardError => e
        result[:errors] += 1
        Ops::StructuredLogger.warn(
          event: "story_intelligence.backfill.error",
          payload: {
            event_id: event&.id,
            error_class: e.class.name,
            error_message: e.message
          }
        )
      end

      result[:reasons] = result[:reasons].sort_by { |_reason, count| -count }.to_h
      log_batch(event: "story_intelligence.backfill.completed", result: result)
      result
    end

    def requeue_generation!
      result = {
        scanned: 0,
        queued: 0,
        skipped_no_context: 0,
        skipped_in_progress: 0,
        skipped_not_needed: 0,
        errors: 0
      }

      story_event_scope.each do |event|
        break if result[:scanned] >= @limit
        next unless event.media.attached?

        result[:scanned] += 1

        if event.llm_comment_in_progress?
          result[:skipped_in_progress] += 1
          next
        end

        unless regeneration_candidate?(event)
          result[:skipped_not_needed] += 1
          next
        end

        payload = with_event_timeout(event: event) { event.send(:local_story_intelligence_payload) }
        next unless payload.is_a?(Hash)
        if event.send(:local_story_intelligence_blank?, payload)
          result[:skipped_no_context] += 1
          next
        end

        event.send(:persist_local_story_intelligence!, payload)
        result[:queued] += 1 if enqueue_comment_job(event, requested_by: "local_story_intelligence_requeue")
      rescue StandardError => e
        result[:errors] += 1
        Ops::StructuredLogger.warn(
          event: "story_intelligence.requeue.error",
          payload: {
            event_id: event&.id,
            error_class: e.class.name,
            error_message: e.message
          }
        )
      end

      log_batch(event: "story_intelligence.requeue.completed", result: result)
      result
    end

    def requeue_pending_video_generation!
      result = {
        scanned: 0,
        queued: 0,
        skipped_non_video: 0,
        skipped_has_comment: 0,
        skipped_in_progress: 0,
        errors: 0
      }

      pending_scope = story_event_scope.where(llm_comment_status: [ nil, "", "not_requested" ])
      pending_scope.each do |event|
        break if result[:scanned] >= @limit
        next unless event.media.attached?

        result[:scanned] += 1

        if event.has_llm_generated_comment?
          result[:skipped_has_comment] += 1
          next
        end

        unless video_story_event?(event)
          result[:skipped_non_video] += 1
          next
        end

        if event.llm_comment_in_progress?
          result[:skipped_in_progress] += 1
          next
        end

        result[:queued] += 1 if enqueue_comment_job(event, requested_by: "local_story_video_requeue")
      rescue StandardError => e
        result[:errors] += 1
        Ops::StructuredLogger.warn(
          event: "story_intelligence.video_requeue.error",
          payload: {
            event_id: event&.id,
            error_class: e.class.name,
            error_message: e.message
          }
        )
      end

      log_batch(event: "story_intelligence.video_requeue.completed", result: result)
      result
    end

    private

    def story_event_scope
      scope = InstagramProfileEvent
        .where(kind: InstagramProfileEvent::STORY_ARCHIVE_EVENT_KINDS)
        .includes(:instagram_profile)
        .order(detected_at: :desc, id: :desc)

      if @account_id.present?
        scope = scope.joins(:instagram_profile).where(instagram_profiles: { instagram_account_id: @account_id })
      end

      scope
    end

    def regeneration_candidate?(event)
      metadata = event.llm_comment_metadata.is_a?(Hash) ? event.llm_comment_metadata : {}
      source = metadata["source"].to_s
      pipeline = metadata["pipeline"].to_s

      return true if event.llm_comment_status.to_s == "failed"
      return true if event.llm_generated_comment.to_s.blank?
      return true if source == "fallback"
      return true if pipeline.present? && pipeline != "local_story_intelligence_v2"

      false
    end

    def enqueue_comment_job(event, requested_by:)
      job = GenerateLlmCommentJob.perform_later(
        instagram_profile_event_id: event.id,
        provider: "local",
        requested_by: requested_by
      )
      event.queue_llm_comment_generation!(job_id: job.job_id)
      true
    rescue StandardError => e
      Ops::StructuredLogger.warn(
        event: "story_intelligence.comment_enqueue.error",
        payload: {
          event_id: event.id,
          requested_by: requested_by,
          error_class: e.class.name,
          error_message: e.message
        }
      )
      false
    end

    def log_batch(event:, result:)
      Ops::StructuredLogger.info(
        event: event,
        payload: {
          account_id: @account_id,
          limit: @limit
        }.merge(result.except(:reasons)).merge(reasons: result[:reasons])
      )
    end

    def with_event_timeout(event:, &block)
      Timeout.timeout(EVENT_TIMEOUT_SECONDS, &block)
    rescue Timeout::Error
      Ops::StructuredLogger.warn(
        event: "story_intelligence.event_timeout",
        payload: {
          event_id: event&.id,
          timeout_seconds: EVENT_TIMEOUT_SECONDS
        }
      )
      nil
    end

    def video_story_event?(event)
      metadata = event.metadata.is_a?(Hash) ? event.metadata : {}
      media_type = metadata["media_type"].to_s
      content_type = event.media&.blob&.content_type.to_s
      media_type.include?("video") || content_type.start_with?("video/")
    rescue StandardError
      false
    end
  end
end
