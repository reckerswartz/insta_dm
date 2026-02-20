require 'active_support/concern'

module InstagramProfileEvent::Broadcastable
  extend ActiveSupport::Concern

  included do
    def broadcast_llm_comment_generation_queued(job_id: nil)
      account = instagram_profile&.instagram_account
      return unless account

      ActionCable.server.broadcast(
        "llm_comment_generation_#{account.id}",
        {
          event_id: id,
          status: "queued",
          job_id: job_id.to_s.presence || llm_comment_job_id,
          message: "Comment generation queued",
          estimated_seconds: estimated_generation_seconds(queue_state: true),
          progress: 5
        }
      )
    rescue StandardError
      nil
    end
    def broadcast_llm_comment_generation_update(generation_result)
      account = instagram_profile&.instagram_account
      return unless account

      ActionCable.server.broadcast(
        "llm_comment_generation_#{account.id}",
        {
          event_id: id,
          status: "completed",
          comment: llm_generated_comment,
          generated_at: llm_comment_generated_at,
          model: llm_comment_model,
          provider: llm_comment_provider,
          relevance_score: llm_comment_relevance_score,
          generation_result: generation_result
        }
      )
    rescue StandardError
      nil
    end
    def broadcast_llm_comment_generation_start
      account = instagram_profile&.instagram_account
      return unless account

      ActionCable.server.broadcast(
        "llm_comment_generation_#{account.id}",
        {
          event_id: id,
          status: "started",
          message: "Generating comment...",
          estimated_seconds: estimated_generation_seconds(queue_state: false),
          progress: 12
        }
      )
    rescue StandardError
      nil
    end
    def broadcast_llm_comment_generation_error(error_message)
      account = instagram_profile&.instagram_account
      return unless account

      ActionCable.server.broadcast(
        "llm_comment_generation_#{account.id}",
        {
          event_id: id,
          status: "error",
          error: error_message,
          message: "Failed to generate comment"
        }
      )
    rescue StandardError
      nil
    end
    def broadcast_llm_comment_generation_skipped(message:, reason: nil, source: nil)
      account = instagram_profile&.instagram_account
      return unless account

      ActionCable.server.broadcast(
        "llm_comment_generation_#{account.id}",
        {
          event_id: id,
          status: "skipped",
          message: message.to_s.presence || "Comment generation skipped",
          reason: reason.to_s.presence,
          source: source.to_s.presence
        }.compact
      )
    rescue StandardError
      nil
    end
    def broadcast_llm_comment_generation_progress(stage:, message:, progress:)
      account = instagram_profile&.instagram_account
      return unless account

      ActionCable.server.broadcast(
        "llm_comment_generation_#{account.id}",
        {
          event_id: id,
          status: "running",
          stage: stage.to_s,
          message: message.to_s,
          progress: progress.to_i.clamp(0, 100),
          estimated_seconds: estimated_generation_seconds(queue_state: false)
        }
      )
    rescue StandardError
      nil
    end
    def self.broadcast_story_archive_refresh!(account:)
      return unless account

      Turbo::StreamsChannel.broadcast_replace_to(
        [account, :story_archive],
        target: "story_media_archive_refresh_signal",
        partial: "instagram_accounts/story_archive_refresh_signal",
        locals: { refreshed_at: Time.current }
      )
    rescue StandardError
      nil
    end
    def broadcast_account_audit_logs_refresh
      account = instagram_profile&.instagram_account
      return unless account

      RefreshAccountAuditLogsJob.enqueue_for(instagram_account_id: account.id, limit: 120)
    rescue StandardError
      nil
    end
    def broadcast_story_archive_refresh
      return unless STORY_ARCHIVE_EVENT_KINDS.include?(kind.to_s)

      account = instagram_profile&.instagram_account
      self.class.broadcast_story_archive_refresh!(account: account)
    rescue StandardError
      nil
    end
    def broadcast_profile_events_refresh
      account_id = instagram_profile&.instagram_account_id
      return unless account_id

      Ops::LiveUpdateBroadcaster.broadcast!(
        topic: "profile_events_changed",
        account_id: account_id,
        payload: { profile_id: instagram_profile_id, event_id: id },
        throttle_key: "profile_events_changed:#{instagram_profile_id}"
      )
    rescue StandardError
      nil
    end

  end
end
