# frozen_string_literal: true

module LlmComment
  class StepRegistry
    Step = Struct.new(
      :key,
      :job_class_name,
      :running_progress,
      :completed_progress,
      :failed_progress,
      :queued_progress,
      keyword_init: true
    )

    STEPS = [
      Step.new(
        key: "ocr_analysis",
        job_class_name: "ProcessStoryCommentOcrJob",
        queued_progress: 8,
        running_progress: 14,
        completed_progress: 26,
        failed_progress: 26
      ),
      Step.new(
        key: "vision_detection",
        job_class_name: "ProcessStoryCommentVisionJob",
        queued_progress: 9,
        running_progress: 16,
        completed_progress: 30,
        failed_progress: 30
      ),
      Step.new(
        key: "face_recognition",
        job_class_name: "ProcessStoryCommentFaceJob",
        queued_progress: 10,
        running_progress: 18,
        completed_progress: 34,
        failed_progress: 34
      ),
      Step.new(
        key: "metadata_extraction",
        job_class_name: "ProcessStoryCommentMetadataJob",
        queued_progress: 11,
        running_progress: 20,
        completed_progress: 38,
        failed_progress: 38
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
