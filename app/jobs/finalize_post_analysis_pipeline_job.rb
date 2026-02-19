class FinalizePostAnalysisPipelineJob < PostAnalysisPipelineJob
  queue_as :ai_visual_queue

  MAX_FINALIZE_ATTEMPTS = ENV.fetch("AI_PIPELINE_FINALIZE_ATTEMPTS", 30).to_i.clamp(5, 120)

  def perform(instagram_account_id:, instagram_profile_id:, instagram_profile_post_id:, pipeline_run_id:, attempts: 0)
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

    maybe_enqueue_metadata_step!(context: context, pipeline_run_id: pipeline_run_id)

    unless pipeline_state.all_required_steps_terminal?(run_id: pipeline_run_id)
      if attempts.to_i >= MAX_FINALIZE_ATTEMPTS
        finalize_as_failed!(
          post: post,
          pipeline_state: pipeline_state,
          pipeline_run_id: pipeline_run_id,
          reason: "pipeline_timeout"
        )
        return
      end

      self.class.set(wait: 5.seconds).perform_later(
        instagram_account_id: account.id,
        instagram_profile_id: profile.id,
        instagram_profile_post_id: post.id,
        pipeline_run_id: pipeline_run_id,
        attempts: attempts.to_i + 1
      )
      return
    end

    pipeline = pipeline_state.pipeline_for(run_id: pipeline_run_id)
    required_steps = Array(pipeline["required_steps"]).map(&:to_s)
    visual_status = pipeline.dig("steps", "visual", "status").to_s
    succeeded_steps = required_steps.select do |step|
      pipeline.dig("steps", step, "status").to_s == "succeeded"
    end
    overall_status =
      if required_steps.include?("visual")
        visual_status == "succeeded" ? "completed" : "failed"
      else
        succeeded_steps.any? ? "completed" : "failed"
      end

    finalize_post_record!(post: post, pipeline: pipeline, overall_status: overall_status)

    pipeline_state.mark_pipeline_finished!(
      run_id: pipeline_run_id,
      status: overall_status,
      details: {
        finalized_by: self.class.name,
        finalized_at: Time.current.iso8601(3),
        attempts: attempts.to_i,
        visual_status: visual_status
      }
    )

    notification_kind = overall_status == "completed" ? "notice" : "alert"
    notification_message =
      if overall_status == "completed"
        "Profile post analyzed: #{post.shortcode}."
      else
        "Profile post analysis degraded/failed for #{post.shortcode}."
      end

    Turbo::StreamsChannel.broadcast_append_to(
      account,
      target: "notifications",
      partial: "shared/notification",
      locals: { kind: notification_kind, message: notification_message }
    )
  rescue StandardError => e
    finalize_as_failed!(
      post: context&.dig(:post),
      pipeline_state: context&.dig(:pipeline_state),
      pipeline_run_id: pipeline_run_id,
      reason: format_error(e)
    )
    raise
  end

  private

  def maybe_enqueue_metadata_step!(context:, pipeline_run_id:)
    pipeline_state = context[:pipeline_state]
    return unless pipeline_state.required_step_pending?(run_id: pipeline_run_id, step: "metadata")
    return unless pipeline_state.core_steps_terminal?(run_id: pipeline_run_id)

    job = ProcessPostMetadataTaggingJob.perform_later(
      instagram_account_id: context[:account].id,
      instagram_profile_id: context[:profile].id,
      instagram_profile_post_id: context[:post].id,
      pipeline_run_id: pipeline_run_id
    )

    pipeline_state.mark_step_queued!(
      run_id: pipeline_run_id,
      step: "metadata",
      queue_name: job.queue_name,
      active_job_id: job.job_id,
      result: {
        enqueued_by: self.class.name,
        enqueued_at: Time.current.iso8601(3)
      }
    )
  rescue StandardError => e
    pipeline_state.mark_step_completed!(
      run_id: pipeline_run_id,
      step: "metadata",
      status: "failed",
      error: format_error(e),
      result: {
        reason: "metadata_enqueue_failed"
      }
    )
  end

  def finalize_post_record!(post:, pipeline:, overall_status:)
    analysis = post.analysis.is_a?(Hash) ? post.analysis.deep_dup : {}
    metadata = post.metadata.is_a?(Hash) ? post.metadata.deep_dup : {}

    ocr_meta = metadata["ocr_analysis"].is_a?(Hash) ? metadata["ocr_analysis"] : {}
    if ocr_meta["ocr_text"].to_s.present?
      analysis["ocr_text"] = ocr_meta["ocr_text"]
      analysis["ocr_blocks"] = Array(ocr_meta["ocr_blocks"]).first(40)
    end

    video_meta = metadata["video_processing"].is_a?(Hash) ? metadata["video_processing"] : {}
    if video_meta.present?
      analysis["video_processing_mode"] = video_meta["processing_mode"].to_s if video_meta["processing_mode"].to_s.present?
      analysis["video_static_detected"] = ActiveModel::Type::Boolean.new.cast(video_meta["static"]) if video_meta.key?("static")
      analysis["video_duration_seconds"] = video_meta["duration_seconds"] if video_meta.key?("duration_seconds")
    end

    metadata["ai_pipeline"] = pipeline

    if overall_status == "completed"
      post.update!(
        analysis: analysis,
        metadata: metadata,
        ai_status: "analyzed",
        analyzed_at: Time.current
      )
    else
      post.update!(
        analysis: analysis,
        metadata: metadata,
        ai_status: "failed",
        analyzed_at: nil
      )
    end
  end

  def finalize_as_failed!(post:, pipeline_state:, pipeline_run_id:, reason:)
    return unless post

    metadata = post.metadata.is_a?(Hash) ? post.metadata.deep_dup : {}
    metadata["ai_pipeline_failure"] = {
      reason: reason.to_s,
      failed_at: Time.current.iso8601(3),
      source: self.class.name
    }

    post.update!(metadata: metadata, ai_status: "failed", analyzed_at: nil)

    pipeline_state&.mark_pipeline_finished!(
      run_id: pipeline_run_id,
      status: "failed",
      details: {
        reason: reason.to_s,
        finalized_at: Time.current.iso8601(3)
      }
    )
  rescue StandardError
    nil
  end
end
