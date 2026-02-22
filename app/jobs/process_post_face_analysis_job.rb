require "timeout"

class ProcessPostFaceAnalysisJob < PostAnalysisStepJob
  queue_as Ops::AiServiceQueueRegistry.queue_symbol_for(:face_analysis)
  MAX_DEFER_ATTEMPTS = ENV.fetch("AI_FACE_MAX_DEFER_ATTEMPTS", 4).to_i.clamp(1, 12)

  retry_on Net::OpenTimeout, Net::ReadTimeout, wait: :polynomially_longer, attempts: 3
  retry_on Errno::ECONNRESET, Errno::ECONNREFUSED, wait: :polynomially_longer, attempts: 3
  retry_on Timeout::Error, wait: :polynomially_longer, attempts: 2

  private

  def step_key
    "face"
  end

  def resource_task_name
    "face"
  end

  def max_defer_attempts
    MAX_DEFER_ATTEMPTS
  end

  def timeout_seconds
    face_timeout_seconds
  end

  def step_failure_reason
    "face_analysis_failed"
  end

  def terminal_blocked?(pipeline_state:, pipeline_run_id:, options: {})
    return false if ActiveModel::Type::Boolean.new.cast(options[:allow_terminal_pipeline])

    pipeline_state.pipeline_terminal?(run_id: pipeline_run_id)
  end

  def perform_step!(context:, pipeline_run_id:, options: {})
    PostFaceRecognitionService.new.process!(post: context[:post])
  end

  def step_completion_result(raw_result:, context:, options: {})
    {
      secondary_run: ActiveModel::Type::Boolean.new.cast(options[:secondary_run]),
      skipped: ActiveModel::Type::Boolean.new.cast(raw_result[:skipped]),
      face_count: raw_result[:face_count].to_i,
      reason: raw_result[:reason].to_s,
      matched_people_count: Array(raw_result[:matched_people]).length
    }
  end

  def face_timeout_seconds
    ENV.fetch("AI_FACE_TIMEOUT_SECONDS", 180).to_i.clamp(20, 420)
  end
end
