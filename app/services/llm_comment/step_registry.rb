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

    STEPS = [
      Step.new(
        key: "face_recognition",
        job_class_name: "ProcessStoryCommentFaceJob",
        blocking: false,
        queued_progress: 10,
        running_progress: 18,
        completed_progress: 34,
        failed_progress: 34
      )
    ].freeze

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
