module Ai
  class PostAnalysisStepReinitializer
    STEP_JOB_MAP = {
      "visual" => ProcessPostVisualAnalysisJob,
      "face" => ProcessPostFaceAnalysisJob,
      "ocr" => ProcessPostOcrAnalysisJob,
      "video" => ProcessPostVideoAnalysisJob,
      "metadata" => ProcessPostMetadataTaggingJob
    }.freeze
    DEFAULT_MAX_REINITIALIZE_ATTEMPTS = ENV.fetch("AI_PIPELINE_STEP_REINITIALIZE_ATTEMPTS", 2).to_i.clamp(1, 6)
    VIDEO_MAX_REINITIALIZE_ATTEMPTS = ENV.fetch("AI_PIPELINE_VIDEO_REINITIALIZE_ATTEMPTS", 0).to_i.clamp(0, 6)

    class << self
      def reinitialize_failed_steps!(account:, profile:, post:, pipeline_state:, pipeline_run_id:, steps:, source_job_id:)
        normalized_steps = Array(steps).map(&:to_s).uniq
        return { enqueued: [], skipped: [] } if normalized_steps.empty?

        pipeline = pipeline_state.pipeline_for(run_id: pipeline_run_id)
        return { enqueued: [], skipped: normalized_steps } unless pipeline.is_a?(Hash)

        required_steps = Array(pipeline["required_steps"]).map(&:to_s)
        enqueued = []
        skipped = []

        normalized_steps.each do |step|
          step_state = pipeline.dig("steps", step).to_h
          unless required_steps.include?(step) && step_state["status"].to_s == "failed"
            skipped << step
            next
          end

          reinit_attempts = step_state.dig("result", "reinitialize_attempts").to_i
          if reinit_attempts >= max_reinitialize_attempts_for(step)
            skipped << step
            next
          end

          job_class = STEP_JOB_MAP[step]
          unless job_class
            skipped << step
            next
          end

          job = job_class.perform_later(
            instagram_account_id: account.id,
            instagram_profile_id: profile.id,
            instagram_profile_post_id: post.id,
            pipeline_run_id: pipeline_run_id
          )

          pipeline_state.mark_step_queued!(
            run_id: pipeline_run_id,
            step: step,
            queue_name: job.queue_name,
            active_job_id: job.job_id,
            result: {
              reason: "step_reinitialized",
              reinitialize_attempts: reinit_attempts + 1,
              reinitialized_by: self.name,
              source_job_id: source_job_id.to_s,
              reinitialized_at: Time.current.iso8601(3)
            }
          )
          enqueued << step
        rescue StandardError
          skipped << step
        end

        { enqueued: enqueued, skipped: skipped }
      end

      private

      def max_reinitialize_attempts_for(step)
        return VIDEO_MAX_REINITIALIZE_ATTEMPTS if step.to_s == "video"

        DEFAULT_MAX_REINITIALIZE_ATTEMPTS
      end
    end
  end
end
