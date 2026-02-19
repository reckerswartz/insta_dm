require "timeout"

class ProcessPostVisualAnalysisJob < PostAnalysisPipelineJob
  queue_as :ai_visual_queue

  retry_on Net::OpenTimeout, Net::ReadTimeout, wait: :polynomially_longer, attempts: 3
  retry_on Errno::ECONNRESET, Errno::ECONNREFUSED, wait: :polynomially_longer, attempts: 3
  retry_on Timeout::Error, wait: :polynomially_longer, attempts: 2

  def perform(instagram_account_id:, instagram_profile_id:, instagram_profile_post_id:, pipeline_run_id:)
    context = load_pipeline_context!(
      instagram_account_id: instagram_account_id,
      instagram_profile_id: instagram_profile_id,
      instagram_profile_post_id: instagram_profile_post_id,
      pipeline_run_id: pipeline_run_id
    )
    return unless context

    account = context[:account]
    profile = context[:profile]
    post = context[:post]
    pipeline_state = context[:pipeline_state]

    pipeline_state.mark_step_running!(
      run_id: pipeline_run_id,
      step: "visual",
      queue_name: queue_name,
      active_job_id: job_id
    )

    builder = Ai::PostAnalysisContextBuilder.new(profile: profile, post: post)
    payload = builder.payload
    media = builder.media_payload
    fingerprint = builder.media_fingerprint(media: media)

    run = Timeout.timeout(visual_timeout_seconds) do
      Ai::Runner.new(account: account).analyze!(
        purpose: "post",
        analyzable: post,
        payload: payload,
        media: media,
        media_fingerprint: fingerprint,
        provider_options: {
          visual_only: true,
          include_faces: false,
          include_ocr: false,
          include_comment_generation: true
        }
      )
    end

    post.update!(
      ai_provider: run[:provider].key,
      ai_model: run.dig(:result, :model),
      analysis: run.dig(:result, :analysis),
      ai_status: "pending"
    )

    pipeline_state.mark_step_completed!(
      run_id: pipeline_run_id,
      step: "visual",
      status: "succeeded",
      result: {
        provider: run[:provider].key,
        model: run.dig(:result, :model),
        ai_analysis_id: run.dig(:record, :id),
        cache_hit: ActiveModel::Type::Boolean.new.cast(run[:cached])
      }
    )
  rescue StandardError => e
    context&.dig(:pipeline_state)&.mark_step_completed!(
      run_id: pipeline_run_id,
      step: "visual",
      status: "failed",
      error: format_error(e),
      result: {
        reason: "visual_analysis_failed"
      }
    )
    raise
  ensure
    if context
      enqueue_pipeline_finalizer(
        account: context[:account],
        profile: context[:profile],
        post: context[:post],
        pipeline_run_id: pipeline_run_id
      )
    end
  end

  private

  def visual_timeout_seconds
    ENV.fetch("AI_VISUAL_TIMEOUT_SECONDS", 210).to_i.clamp(30, 600)
  end
end
