# frozen_string_literal: true

module LlmComment
  class StepRegistry
    Step = Struct.new(
      :key,
      :job_class_name,
      :blocking,
      :running_progress,
      :completed_progress,
      :failed_progress,
      :queued_progress,
      keyword_init: true
    )

    # Phase 12 removed the only registered step (`face_recognition`)
    # when ProcessStoryCommentFaceJob + its backing services were
    # deleted. The registry stays in place as an extension point so a
    # future step (e.g. a pre-LLM moderation check) can opt back in
    # without re-wiring every caller.
    STEPS = [].freeze

    class << self
      def steps
        STEPS
      end

      def step_for(key)
        steps.find { |step| step.key.to_s == key.to_s }
      end

      def step_keys
        steps.map(&:key)
      end

      def required_step_keys
        steps.select { |step| step.blocking == true }.map(&:key)
      end

      def deferred_step_keys
        steps.reject { |step| step.blocking == true }.map(&:key)
      end

      def stage_job_map
        @stage_job_map ||= steps.each_with_object({}) do |step, out|
          klass = step.job_class_name.to_s.safe_constantize
          out[step.key] = klass if klass
        end
      end

      def progress_for(step:, state:)
        row = step_for(step)
        return default_progress(state) unless row

        case state.to_s
        when "queued"
          row.queued_progress
        when "running"
          row.running_progress
        when "completed"
          row.completed_progress
        when "failed"
          row.failed_progress
        else
          default_progress(state)
        end
      end

      private

      def default_progress(state)
        return 8 if state.to_s == "queued"
        20
      end
    end
  end
end
