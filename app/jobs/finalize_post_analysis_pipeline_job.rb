class FinalizePostAnalysisPipelineJob < PostAnalysisPipelineJob
  queue_as :ai_visual_queue

  MAX_FINALIZE_ATTEMPTS = ENV.fetch("AI_PIPELINE_FINALIZE_ATTEMPTS", 30).to_i.clamp(5, 120)
  FINALIZER_LOCK_SECONDS = ENV.fetch("AI_PIPELINE_FINALIZER_LOCK_SECONDS", 4).to_i.clamp(2, 30)
  STEP_STALL_TIMEOUT_SECONDS = ENV.fetch("AI_PIPELINE_STEP_STALL_TIMEOUT_SECONDS", 180).to_i.clamp(45, 1800)

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
    if pipeline_state.pipeline_terminal?(run_id: pipeline_run_id)
      Ops::StructuredLogger.info(
        event: "ai.pipeline.finalizer.skipped_terminal",
        payload: {
          active_job_id: job_id,
          instagram_account_id: account.id,
          instagram_profile_id: profile.id,
          instagram_profile_post_id: post.id,
          pipeline_run_id: pipeline_run_id
        }
      )
      return
    end

    return unless acquire_finalizer_slot?(post: post, pipeline_run_id: pipeline_run_id, attempts: attempts)

    maybe_enqueue_metadata_step!(context: context, pipeline_run_id: pipeline_run_id)
    mark_stalled_steps_failed!(context: context, pipeline_run_id: pipeline_run_id)

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

      wait_seconds = finalize_poll_delay_seconds(attempts: attempts)
      self.class.set(wait: wait_seconds.seconds).perform_later(
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

  def acquire_finalizer_slot?(post:, pipeline_run_id:, attempts:)
    now = Time.current
    acquired = false

    post.with_lock do
      metadata = post.metadata.is_a?(Hash) ? post.metadata.deep_dup : {}
      pipeline = metadata["ai_pipeline"]
      unless pipeline.is_a?(Hash) && pipeline["run_id"].to_s == pipeline_run_id.to_s
        acquired = false
        next
      end

      finalizer = pipeline["finalizer"].is_a?(Hash) ? pipeline["finalizer"] : {}
      lock_until = parse_time(finalizer["lock_until"])
      if lock_until.present? && lock_until > now
        acquired = false
        next
      end

      finalizer["lock_until"] = (now + FINALIZER_LOCK_SECONDS.seconds).iso8601(3)
      finalizer["last_started_at"] = now.iso8601(3)
      finalizer["last_job_id"] = job_id
      finalizer["last_attempt"] = attempts.to_i
      pipeline["finalizer"] = finalizer
      metadata["ai_pipeline"] = pipeline
      post.update!(metadata: metadata)
      acquired = true
    end

    acquired
  rescue StandardError
    true
  end

  def finalize_poll_delay_seconds(attempts:)
    value = attempts.to_i
    return 5 if value < 3
    return 10 if value < 8
    return 15 if value < 14
    return 20 if value < 20

    30
  end

  def parse_time(value)
    return nil if value.to_s.blank?

    Time.zone.parse(value.to_s)
  rescue StandardError
    nil
  end

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
      metadata.delete("ai_pipeline_failure")
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

  def mark_stalled_steps_failed!(context:, pipeline_run_id:)
    pipeline_state = context[:pipeline_state]
    pipeline = pipeline_state.pipeline_for(run_id: pipeline_run_id)
    return unless pipeline.is_a?(Hash)

    required_steps = Array(pipeline["required_steps"]).map(&:to_s)
    return if required_steps.empty?

    now = Time.current
    required_steps.each do |step|
      row = pipeline.dig("steps", step)
      next unless row.is_a?(Hash)

      status = row["status"].to_s
      next unless status.in?(%w[queued running])

      age_seconds = step_age_seconds(step_row: row, pipeline: pipeline, now: now)
      next unless age_seconds
      next if age_seconds < STEP_STALL_TIMEOUT_SECONDS

      pipeline_state.mark_step_completed!(
        run_id: pipeline_run_id,
        step: step,
        status: "failed",
        error: "step_stalled_timeout: status=#{status} age_seconds=#{age_seconds.to_i}",
        result: {
          reason: "step_stalled_timeout",
          previous_status: status,
          age_seconds: age_seconds.to_i,
          timeout_seconds: STEP_STALL_TIMEOUT_SECONDS
        }
      )

      Ops::StructuredLogger.warn(
        event: "ai.pipeline.step_stalled",
        payload: {
          active_job_id: job_id,
          instagram_account_id: context[:account].id,
          instagram_profile_id: context[:profile].id,
          instagram_profile_post_id: context[:post].id,
          pipeline_run_id: pipeline_run_id,
          step: step,
          previous_status: status,
          age_seconds: age_seconds.to_i,
          timeout_seconds: STEP_STALL_TIMEOUT_SECONDS
        }
      )
    end
  rescue StandardError
    nil
  end

  def step_age_seconds(step_row:, pipeline:, now:)
    reference =
      parse_time(step_row["started_at"]) ||
      parse_time(step_row.dig("result", "enqueued_at")) ||
      parse_time(step_row["created_at"]) ||
      parse_time(pipeline["updated_at"]) ||
      parse_time(pipeline["created_at"])
    return nil unless reference

    (now - reference).to_f
  rescue StandardError
    nil
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
