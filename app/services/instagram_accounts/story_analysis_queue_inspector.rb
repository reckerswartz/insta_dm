module InstagramAccounts
  class StoryAnalysisQueueInspector
    STALE_AFTER = ENV.fetch("STORY_ANALYSIS_STALE_AFTER_SECONDS", "600").to_i.clamp(60, 86_400).seconds
    ANALYSIS_QUEUE_NAME = Ops::AiServiceQueueRegistry.queue_name_for(:story_analysis).to_s.presence || "story_analysis"

    def stale_job?(event:)
      return false unless sidekiq_adapter?

      metadata = event.metadata.is_a?(Hash) ? event.metadata : {}
      status = metadata["status"].to_s
      return false unless status.in?(%w[queued started running processing])

      freshness_marker = parse_time(metadata["status_updated_at"]) || event.updated_at || event.detected_at
      return false if freshness_marker && freshness_marker > STALE_AFTER.ago

      active_job_id = metadata["active_job_id"].to_s
      markers = [
        active_job_id,
        metadata["story_id"].to_s.presence
      ].compact

      return false if currently_busy?(markers: markers)
      return false if queued?(markers: markers)
      return false if retrying?(markers: markers)
      return false if scheduled?(markers: markers)

      true
    rescue StandardError
      false
    end

    private

    def sidekiq_adapter?
      Rails.application.config.active_job.queue_adapter.to_s == "sidekiq"
    end

    def currently_busy?(markers:)
      return false if markers.empty?

      require "sidekiq/api"
      Sidekiq::Workers.new.any? do |_pid, _tid, work|
        payload = work["payload"].to_s
        marker_match?(payload: payload, markers: markers)
      end
    end

    def queued?(markers:)
      return false if markers.empty?

      require "sidekiq/api"
      Sidekiq::Queue.new(ANALYSIS_QUEUE_NAME).any? do |job|
        payload = job.item.to_s
        marker_match?(payload: payload, markers: markers)
      end
    end

    def retrying?(markers:)
      return false if markers.empty?

      require "sidekiq/api"
      Sidekiq::RetrySet.new.any? do |job|
        payload = job.item.to_s
        marker_match?(payload: payload, markers: markers)
      end
    end

    def scheduled?(markers:)
      return false if markers.empty?

      require "sidekiq/api"
      Sidekiq::ScheduledSet.new.any? do |job|
        payload = job.item.to_s
        marker_match?(payload: payload, markers: markers)
      end
    end

    def marker_match?(payload:, markers:)
      markers.any? do |marker|
        token = marker.to_s
        next false if token.blank?

        payload.include?(token)
      end
    end

    def parse_time(value)
      return nil if value.blank?

      Time.zone.parse(value.to_s)
    rescue StandardError
      nil
    end
  end
end
