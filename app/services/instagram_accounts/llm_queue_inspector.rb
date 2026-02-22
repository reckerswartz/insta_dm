module InstagramAccounts
  class LlmQueueInspector
    STALE_AFTER = 5.minutes
    LLM_QUEUE_NAME = Ops::AiServiceQueueRegistry.queue_name_for(:llm_comment_generation).to_s.presence || "ai_llm_comment_queue"

    def queue_size
      return 0 unless sidekiq_adapter?

      require "sidekiq/api"
      Sidekiq::Queue.new(LLM_QUEUE_NAME).size.to_i
    rescue StandardError
      0
    end

    def stale_comment_job?(event:)
      return false unless event.llm_comment_in_progress?
      return false if event.updated_at && event.updated_at > STALE_AFTER.ago
      return false unless sidekiq_adapter?

      require "sidekiq/api"
      job_id = event.llm_comment_job_id.to_s
      event_marker = "instagram_profile_event_id\"=>#{event.id}"

      return false if currently_busy?(job_id: job_id, event_marker: event_marker)
      return false if queued?(job_id: job_id, event_marker: event_marker)
      return false if retrying?(job_id: job_id, event_marker: event_marker)
      return false if scheduled?(job_id: job_id, event_marker: event_marker)

      true
    rescue StandardError
      false
    end

    private

    def sidekiq_adapter?
      Rails.application.config.active_job.queue_adapter.to_s == "sidekiq"
    end

    def currently_busy?(job_id:, event_marker:)
      Sidekiq::Workers.new.any? do |_pid, _tid, work|
        payload = work["payload"].to_s
        payload.include?(job_id) || payload.include?(event_marker)
      end
    end

    def queued?(job_id:, event_marker:)
      tracked_queue_names.any? do |queue_name|
        Sidekiq::Queue.new(queue_name).any? do |job|
          payload = job.item.to_s
          payload.include?(job_id) || payload.include?(event_marker)
        end
      end
    end

    def retrying?(job_id:, event_marker:)
      Sidekiq::RetrySet.new.any? do |job|
        payload = job.item.to_s
        payload.include?(job_id) || payload.include?(event_marker)
      end
    end

    def scheduled?(job_id:, event_marker:)
      Sidekiq::ScheduledSet.new.any? do |job|
        payload = job.item.to_s
        payload.include?(job_id) || payload.include?(event_marker)
      end
    end

    def tracked_queue_names
      @tracked_queue_names ||= [
        Ops::AiServiceQueueRegistry.queue_name_for(:llm_comment_generation),
        Ops::AiServiceQueueRegistry.queue_name_for(:pipeline_orchestration)
      ].map(&:to_s).reject(&:blank?).uniq
    end
  end
end
