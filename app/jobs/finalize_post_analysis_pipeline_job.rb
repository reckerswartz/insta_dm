class FinalizePostAnalysisPipelineJob < PostAnalysisPipelineJob
  queue_as Ops::AiServiceQueueRegistry.queue_symbol_for(:pipeline_orchestration)

  MAX_FINALIZE_ATTEMPTS = ENV.fetch("AI_PIPELINE_FINALIZE_ATTEMPTS", 30).to_i.clamp(5, 120)
  FINALIZER_LOCK_SECONDS = ENV.fetch("AI_PIPELINE_FINALIZER_LOCK_SECONDS", 4).to_i.clamp(2, 30)
  STEP_STALL_TIMEOUT_SECONDS = ENV.fetch("AI_PIPELINE_STEP_STALL_TIMEOUT_SECONDS", 180).to_i.clamp(45, 1800)
  SECONDARY_FACE_QUEUE = Ops::AiServiceQueueRegistry.queue_name_for(:face_analysis_secondary).presence || "ai_face_secondary_queue"
  SECONDARY_FACE_MIN_CONFIDENCE = ENV.fetch("AI_SECONDARY_FACE_AMBIGUITY_MIN_CONFIDENCE", "0.35").to_f.clamp(0.0, 1.0)
  SECONDARY_FACE_MAX_CONFIDENCE = ENV.fetch("AI_SECONDARY_FACE_AMBIGUITY_MAX_CONFIDENCE", "0.68").to_f.clamp(0.0, 1.0)
  VIDEO_FAILURE_FALLBACK_ENABLED = ActiveModel::Type::Boolean.new.cast(
    ENV.fetch("AI_PIPELINE_VIDEO_FAILURE_FALLBACK_ENABLED", "true")
  )
  VIDEO_FAILURE_FALLBACK_REQUIRE_VISUAL_SUCCESS = ActiveModel::Type::Boolean.new.cast(
    ENV.fetch("AI_PIPELINE_VIDEO_FAILURE_FALLBACK_REQUIRE_VISUAL_SUCCESS", "true")
  )

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

    mark_stalled_steps_failed!(context: context, pipeline_run_id: pipeline_run_id)
    apply_video_failure_fallback!(context: context, pipeline_run_id: pipeline_run_id)
    return if reinitialize_failed_core_steps!(context: context, pipeline_run_id: pipeline_run_id)
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

    maybe_enqueue_secondary_face_step!(context: context, pipeline_run_id: pipeline_run_id)

    pipeline = pipeline_state.pipeline_for(run_id: pipeline_run_id)
    required_steps = Array(pipeline["required_steps"]).map(&:to_s)
    failed_steps = required_steps.select do |step|
      pipeline.dig("steps", step, "status").to_s == "failed"
    end
    succeeded_steps = required_steps.select { |step| pipeline.dig("steps", step, "status").to_s == "succeeded" }
    overall_status = failed_steps.any? ? "failed" : (succeeded_steps.length == required_steps.length ? "completed" : "failed")

    finalize_post_record!(post: post, pipeline: pipeline, overall_status: overall_status)

    pipeline_state.mark_pipeline_finished!(
      run_id: pipeline_run_id,
      status: overall_status,
      details: {
        finalized_by: self.class.name,
        finalized_at: Time.current.iso8601(3),
        attempts: attempts.to_i,
        failed_steps: failed_steps
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

    # Every pipeline step enqueues a finalizer; this short lock serializes metadata writes.
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
    # Metadata tagging depends on successful outputs from core extraction steps.
    unless pipeline_state.core_steps_succeeded?(run_id: pipeline_run_id)
      if pipeline_state.core_steps_terminal?(run_id: pipeline_run_id)
        failed_core_steps = pipeline_state.failed_required_steps(run_id: pipeline_run_id, include_metadata: false)
        pipeline_state.mark_step_completed!(
          run_id: pipeline_run_id,
          step: "metadata",
          status: "failed",
          error: "core_dependencies_failed: #{failed_core_steps.join(',')}",
          result: {
            reason: "core_dependencies_failed",
            failed_core_steps: failed_core_steps
          }
        )
      end
      return
    end

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

  def reinitialize_failed_core_steps!(context:, pipeline_run_id:)
    pipeline_state = context[:pipeline_state]
    failed_steps = pipeline_state.failed_required_steps(run_id: pipeline_run_id, include_metadata: false)
    return false if failed_steps.empty?

    result = Ai::PostAnalysisStepReinitializer.reinitialize_failed_steps!(
      account: context[:account],
      profile: context[:profile],
      post: context[:post],
      pipeline_state: pipeline_state,
      pipeline_run_id: pipeline_run_id,
      steps: failed_steps,
      source_job_id: job_id
    )

    enqueued = Array(result[:enqueued]).map(&:to_s)
    return false if enqueued.empty?

    Ops::StructuredLogger.info(
      event: "ai.pipeline.steps_reinitialized",
      payload: {
        active_job_id: job_id,
        instagram_account_id: context[:account].id,
        instagram_profile_id: context[:profile].id,
        instagram_profile_post_id: context[:post].id,
        pipeline_run_id: pipeline_run_id,
        reinitialized_steps: enqueued,
        skipped_steps: Array(result[:skipped]).map(&:to_s)
      }
    )

    enqueue_pipeline_finalizer(
      account: context[:account],
      profile: context[:profile],
      post: context[:post],
      pipeline_run_id: pipeline_run_id,
      attempts: 0
    )
    true
  rescue StandardError
    false
  end

  def apply_video_failure_fallback!(context:, pipeline_run_id:)
    return unless VIDEO_FAILURE_FALLBACK_ENABLED

    pipeline_state = context[:pipeline_state]
    pipeline = pipeline_state.pipeline_for(run_id: pipeline_run_id)
    return unless pipeline.is_a?(Hash)

    required_steps = Array(pipeline["required_steps"]).map(&:to_s)
    return unless required_steps.include?("video")

    video_step = pipeline.dig("steps", "video")
    return unless video_step.is_a?(Hash)
    return unless video_step["status"].to_s == "failed"

    if VIDEO_FAILURE_FALLBACK_REQUIRE_VISUAL_SUCCESS
      visual_status = pipeline.dig("steps", "visual", "status").to_s
      return unless visual_status == "succeeded"
    end

    fallback_result = build_video_fallback_result(post: context[:post], video_step: video_step)
    pipeline_state.mark_step_completed!(
      run_id: pipeline_run_id,
      step: "video",
      status: "succeeded",
      result: fallback_result
    )
    persist_video_fallback_metadata!(
      post: context[:post],
      fallback_result: fallback_result,
      previous_error: video_step["error"]
    )

    Ops::StructuredLogger.warn(
      event: "ai.pipeline.video_fallback_applied",
      payload: {
        active_job_id: job_id,
        instagram_account_id: context[:account].id,
        instagram_profile_id: context[:profile].id,
        instagram_profile_post_id: context[:post].id,
        pipeline_run_id: pipeline_run_id,
        fallback_reason: fallback_result[:reason].to_s,
        reused_existing_context: ActiveModel::Type::Boolean.new.cast(fallback_result[:reused_existing_context]),
        previous_error: video_step["error"].to_s.byteslice(0, 200)
      }.compact
    )
  rescue StandardError
    nil
  end

  def build_video_fallback_result(post:, video_step:)
    metadata = post.metadata.is_a?(Hash) ? post.metadata : {}
    video_meta = metadata["video_processing"].is_a?(Hash) ? metadata["video_processing"] : {}
    reused_existing_context =
      video_meta["context_summary"].to_s.present? ||
      video_meta["transcript"].to_s.present? ||
      Array(video_meta["topics"]).any? ||
      Array(video_meta["objects"]).any?

    {
      reason: "video_step_failed_fallback_to_visual_metadata",
      fallback_applied: true,
      reused_existing_context: reused_existing_context,
      previous_error: video_step["error"].to_s.presence,
      previous_status: video_step["status"].to_s,
      processing_mode: video_meta["processing_mode"].to_s.presence || "dynamic_video",
      transcript_present: video_meta["transcript"].to_s.present?
    }.compact
  end

  def persist_video_fallback_metadata!(post:, fallback_result:, previous_error:)
    post.with_lock do
      post.reload
      metadata = post.metadata.is_a?(Hash) ? post.metadata.deep_dup : {}
      video_meta = metadata["video_processing"].is_a?(Hash) ? metadata["video_processing"].deep_dup : {}

      video_meta["skipped"] = true if video_meta["skipped"].nil?
      video_meta["processing_mode"] = fallback_result[:processing_mode].to_s.presence || "dynamic_video"
      video_meta["context_summary"] ||= "Video deep analysis was skipped to keep pipeline latency low; visual and metadata signals were used."
      video_meta["fallback"] = {
        "applied" => true,
        "reason" => fallback_result[:reason].to_s,
        "reused_existing_context" => ActiveModel::Type::Boolean.new.cast(fallback_result[:reused_existing_context]),
        "previous_error" => previous_error.to_s.presence,
        "applied_at" => Time.current.iso8601(3)
      }.compact
      video_meta["updated_at"] = Time.current.iso8601(3)

      metadata["video_processing"] = video_meta
      post.update!(metadata: metadata)
    end
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
      analysis["video_semantic_route"] = video_meta["semantic_route"].to_s if video_meta["semantic_route"].to_s.present?
      analysis["video_duration_seconds"] = video_meta["duration_seconds"] if video_meta.key?("duration_seconds")
      analysis["video_context_summary"] = video_meta["context_summary"].to_s if video_meta["context_summary"].to_s.present?
      analysis["transcript"] = video_meta["transcript"].to_s if video_meta["transcript"].to_s.present?
      analysis["video_topics"] = normalize_string_array(video_meta["topics"], limit: 40)
      analysis["video_objects"] = normalize_string_array(video_meta["objects"], limit: 50)
      analysis["video_scenes"] = Array(video_meta["scenes"]).select { |row| row.is_a?(Hash) }.first(50)
      analysis["video_hashtags"] = normalize_string_array(video_meta["hashtags"], limit: 50)
      analysis["video_mentions"] = normalize_string_array(video_meta["mentions"], limit: 50)
      analysis["video_profile_handles"] = normalize_string_array(video_meta["profile_handles"], limit: 50)

      analysis["topics"] = merge_string_array(analysis["topics"], video_meta["topics"], limit: 40)
      analysis["objects"] = merge_string_array(analysis["objects"], video_meta["objects"], limit: 50)
      analysis["hashtags"] = merge_string_array(analysis["hashtags"], video_meta["hashtags"], limit: 50)
      analysis["mentions"] = merge_string_array(analysis["mentions"], video_meta["mentions"], limit: 50)

      if analysis["ocr_text"].to_s.blank? && video_meta["ocr_text"].to_s.present?
        analysis["ocr_text"] = video_meta["ocr_text"].to_s
      end
      if Array(analysis["ocr_blocks"]).empty?
        analysis["ocr_blocks"] = Array(video_meta["ocr_blocks"]).select { |row| row.is_a?(Hash) }.first(40)
      end
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

  def maybe_enqueue_secondary_face_step!(context:, pipeline_run_id:)
    pipeline_state = context[:pipeline_state]
    pipeline = pipeline_state.pipeline_for(run_id: pipeline_run_id)
    return unless pipeline.is_a?(Hash)

    task_flags = pipeline["task_flags"].is_a?(Hash) ? pipeline["task_flags"] : {}
    required_steps = Array(pipeline["required_steps"]).map(&:to_s)
    face_required = required_steps.include?("face")
    face_state = pipeline.dig("steps", "face").to_h
    face_status = face_state["status"].to_s

    return if face_required || !face_status.in?(%w[skipped pending])
    return unless ActiveModel::Type::Boolean.new.cast(task_flags["secondary_face_analysis"])

    primary_confidence = primary_confidence_for(post: context[:post])
    if secondary_only_on_ambiguous?(task_flags: task_flags) && !ambiguous_primary_confidence?(primary_confidence)
      pipeline_state.mark_step_completed!(
        run_id: pipeline_run_id,
        step: "face",
        status: "skipped",
        result: {
          reason: "secondary_face_not_needed",
          secondary_face_analysis: true,
          primary_confidence: primary_confidence
        }
      )
      return
    end

    guard = Ops::ResourceGuard.allow_ai_task?(task: "face_secondary", queue_name: SECONDARY_FACE_QUEUE, critical: false)
    unless ActiveModel::Type::Boolean.new.cast(guard[:allow])
      pipeline_state.mark_step_completed!(
        run_id: pipeline_run_id,
        step: "face",
        status: "skipped",
        error: "secondary_face_resource_constrained: #{guard[:reason]}",
        result: {
          reason: "secondary_face_resource_constrained",
          secondary_face_analysis: true,
          primary_confidence: primary_confidence,
          snapshot: guard[:snapshot]
        }
      )
      return
    end

    job = ProcessPostFaceAnalysisJob.set(queue: SECONDARY_FACE_QUEUE).perform_later(
      instagram_account_id: context[:account].id,
      instagram_profile_id: context[:profile].id,
      instagram_profile_post_id: context[:post].id,
      pipeline_run_id: pipeline_run_id,
      allow_terminal_pipeline: true,
      secondary_run: true
    )

    pipeline_state.mark_step_queued!(
      run_id: pipeline_run_id,
      step: "face",
      queue_name: job.queue_name,
      active_job_id: job.job_id,
      result: {
        reason: "secondary_face_enqueued",
        secondary_face_analysis: true,
        primary_confidence: primary_confidence,
        enqueued_by: self.class.name,
        enqueued_at: Time.current.iso8601(3)
      }
    )
  rescue StandardError => e
    pipeline_state.mark_step_completed!(
      run_id: pipeline_run_id,
      step: "face",
      status: "skipped",
      error: "secondary_face_enqueue_failed: #{format_error(e)}",
      result: {
        reason: "secondary_face_enqueue_failed"
      }
    )
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

  def normalize_string_array(values, limit:)
    Array(values).map(&:to_s).map(&:strip).reject(&:blank?).uniq.first(limit)
  end

  def merge_string_array(existing, incoming, limit:)
    normalize_string_array(Array(existing) + Array(incoming), limit: limit)
  end

  def secondary_only_on_ambiguous?(task_flags:)
    return true unless task_flags.key?("secondary_only_on_ambiguous")

    ActiveModel::Type::Boolean.new.cast(task_flags["secondary_only_on_ambiguous"])
  end

  def ambiguous_primary_confidence?(value)
    score = value.to_f.clamp(0.0, 1.0)
    score >= SECONDARY_FACE_MIN_CONFIDENCE && score <= SECONDARY_FACE_MAX_CONFIDENCE
  end

  def primary_confidence_for(post:)
    analysis = post.analysis.is_a?(Hash) ? post.analysis : {}
    metadata = post.metadata.is_a?(Hash) ? post.metadata : {}

    base_confidence = analysis["confidence"].to_f
    base_confidence = 0.55 if base_confidence <= 0.0

    mention_count = normalize_string_array(analysis["mentions"], limit: 50).length
    hashtag_count = normalize_string_array(analysis["hashtags"], limit: 50).length
    ocr_text_present = analysis["ocr_text"].to_s.present? || metadata.dig("ocr_analysis", "ocr_text").to_s.present?
    transcript_present = analysis["transcript"].to_s.present? || metadata.dig("video_processing", "transcript").to_s.present?

    score = base_confidence
    score += 0.08 if mention_count.positive?
    score += 0.04 if hashtag_count.positive?
    score += 0.08 if ocr_text_present
    score += 0.08 if transcript_present
    score += 0.05 if post.caption.to_s.include?("@")
    score += 0.05 if post.caption.to_s.include?("#")

    score.clamp(0.0, 1.0).round(4)
  rescue StandardError
    0.55
  end
end
