require "timeout"

class ProcessPostFaceAnalysisJob < PostAnalysisPipelineJob
  queue_as :ai_face_queue

  retry_on Net::OpenTimeout, Net::ReadTimeout, wait: :polynomially_longer, attempts: 3
  retry_on Errno::ECONNRESET, Errno::ECONNREFUSED, wait: :polynomially_longer, attempts: 3
  retry_on Timeout::Error, wait: :polynomially_longer, attempts: 2

  def perform(instagram_account_id:, instagram_profile_id:, instagram_profile_post_id:, pipeline_run_id:)
    enqueue_finalizer = true
    context = load_pipeline_context!(
      instagram_account_id: instagram_account_id,
      instagram_profile_id: instagram_profile_id,
      instagram_profile_post_id: instagram_profile_post_id,
      pipeline_run_id: pipeline_run_id
    )
    return unless context

    pipeline_state = context[:pipeline_state]
    post = context[:post]
    if pipeline_state.pipeline_terminal?(run_id: pipeline_run_id) || pipeline_state.step_terminal?(run_id: pipeline_run_id, step: "face")
      enqueue_finalizer = false
      Ops::StructuredLogger.info(
        event: "ai.face_analysis.skipped_terminal",
        payload: {
          active_job_id: job_id,
          instagram_account_id: context[:account].id,
          instagram_profile_id: context[:profile].id,
          instagram_profile_post_id: post.id,
          pipeline_run_id: pipeline_run_id
        }
      )
      return
    end

    pipeline_state.mark_step_running!(
      run_id: pipeline_run_id,
      step: "face",
      queue_name: queue_name,
      active_job_id: job_id
    )

    result = Timeout.timeout(face_timeout_seconds) do
      PostFaceRecognitionService.new.process!(post: post)
    end

    pipeline_state.mark_step_completed!(
      run_id: pipeline_run_id,
      step: "face",
      status: "succeeded",
      result: {
        skipped: ActiveModel::Type::Boolean.new.cast(result[:skipped]),
        face_count: result[:face_count].to_i,
        reason: result[:reason].to_s,
        matched_people_count: Array(result[:matched_people]).length
      }
    )
  rescue StandardError => e
    context&.dig(:pipeline_state)&.mark_step_completed!(
      run_id: pipeline_run_id,
      step: "face",
      status: "failed",
      error: format_error(e),
      result: {
        reason: "face_analysis_failed"
      }
    )
    raise
  ensure
    if context && enqueue_finalizer
      enqueue_pipeline_finalizer(
        account: context[:account],
        profile: context[:profile],
        post: context[:post],
        pipeline_run_id: pipeline_run_id
      )
    end
  end

  private

  def face_timeout_seconds
    ENV.fetch("AI_FACE_TIMEOUT_SECONDS", 180).to_i.clamp(20, 420)
  end
end
