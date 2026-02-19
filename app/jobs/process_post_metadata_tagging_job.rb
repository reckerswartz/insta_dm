class ProcessPostMetadataTaggingJob < PostAnalysisPipelineJob
  queue_as :ai_metadata_queue

  PROFILE_INCOMPLETE_REASON_CODES = %w[
    latest_posts_not_analyzed
    insufficient_analyzed_posts
    no_recent_posts_available
    missing_structured_post_signals
    profile_preparation_failed
    profile_preparation_error
  ].freeze
  COMMENT_RETRY_MAX_ATTEMPTS = ENV.fetch("POST_COMMENT_RETRY_MAX_ATTEMPTS", 3).to_i.clamp(1, 10)

  def perform(instagram_account_id:, instagram_profile_id:, instagram_profile_post_id:, pipeline_run_id:)
    enqueue_finalizer = true
    context = load_pipeline_context!(
      instagram_account_id: instagram_account_id,
      instagram_profile_id: instagram_profile_id,
      instagram_profile_post_id: instagram_profile_post_id,
      pipeline_run_id: pipeline_run_id
    )
    return unless context

    account = context[:account]
    post = context[:post]
    profile = context[:profile]
    pipeline_state = context[:pipeline_state]
    if pipeline_state.pipeline_terminal?(run_id: pipeline_run_id) || pipeline_state.step_terminal?(run_id: pipeline_run_id, step: "metadata")
      enqueue_finalizer = false
      Ops::StructuredLogger.info(
        event: "ai.metadata_tagging.skipped_terminal",
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

    pipeline_state.mark_step_running!(
      run_id: pipeline_run_id,
      step: "metadata",
      queue_name: queue_name,
      active_job_id: job_id
    )

    analysis = post.analysis.is_a?(Hash) ? post.analysis.deep_dup : {}
    face_meta = post.metadata.is_a?(Hash) ? post.metadata.dig("face_recognition") : nil
    face_meta = {} unless face_meta.is_a?(Hash)
    matched_people = Array(face_meta["matched_people"])

    analysis["face_summary"] = {
      "face_count" => face_meta["face_count"].to_i,
      "owner_faces_count" => matched_people.count { |row| ActiveModel::Type::Boolean.new.cast(row["owner_match"] || row[:owner_match]) },
      "recurring_faces_count" => matched_people.count { |row| ActiveModel::Type::Boolean.new.cast(row["recurring_face"] || row[:recurring_face]) },
      "detection_source" => face_meta["detection_source"].to_s.presence,
      "participant_summary" => face_meta["participant_summary"].to_s.presence,
      "detection_reason" => face_meta["detection_reason"].to_s.presence,
      "detection_error" => face_meta["detection_error"].to_s.presence
    }.compact

    post.update!(analysis: analysis)

    Ai::ProfileAutoTagger.sync_from_post_analysis!(profile: profile, analysis: analysis)

    comment_result =
      if comment_generation_enabled?(pipeline_state: pipeline_state, pipeline_run_id: pipeline_run_id)
        Ai::PostCommentGenerationService.new(
          account: account,
          profile: profile,
          post: post,
          enforce_required_evidence: comment_evidence_policy_enforced?(pipeline_state: pipeline_state, pipeline_run_id: pipeline_run_id)
        ).run!
      else
        {
          blocked: true,
          status: "disabled_by_task_flags",
          source: "policy",
          suggestions_count: 0,
          reason_code: "comments_disabled"
        }
      end

    retry_result =
      if comment_retry_enabled?(pipeline_state: pipeline_state, pipeline_run_id: pipeline_run_id)
        enqueue_comment_retry_if_needed!(
          account: account,
          profile: profile,
          post: post,
          comment_result: comment_result
        )
      else
        { queued: false, reason: "retry_disabled" }
      end

    pipeline_state.mark_step_completed!(
      run_id: pipeline_run_id,
      step: "metadata",
      status: "succeeded",
      result: {
        face_count: face_meta["face_count"].to_i,
        participant_summary_present: face_meta["participant_summary"].to_s.present?,
        comment_generation_status: comment_result[:status].to_s,
        comment_generation_blocked: ActiveModel::Type::Boolean.new.cast(comment_result[:blocked]),
        comment_generation_source: comment_result[:source].to_s,
        comment_suggestions_count: comment_result[:suggestions_count].to_i,
        comment_reason_code: comment_result[:reason_code].to_s.presence,
        comment_history_reason_code: comment_result[:history_reason_code].to_s.presence,
        comment_retry_queued: ActiveModel::Type::Boolean.new.cast(retry_result[:queued]),
        comment_retry_reason: retry_result[:reason].to_s.presence,
        comment_retry_job_id: retry_result[:job_id].to_s.presence,
        comment_retry_next_run_at: retry_result[:next_run_at].to_s.presence
      }
    )
  rescue StandardError => e
    context&.dig(:pipeline_state)&.mark_step_completed!(
      run_id: pipeline_run_id,
      step: "metadata",
      status: "failed",
      error: format_error(e),
      result: {
        reason: "metadata_tagging_failed"
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

  def comment_generation_enabled?(pipeline_state:, pipeline_run_id:)
    pipeline = pipeline_state.pipeline_for(run_id: pipeline_run_id)
    flags = pipeline.is_a?(Hash) ? pipeline["task_flags"] : {}
    flags = {} unless flags.is_a?(Hash)

    if flags.key?("generate_comments")
      ActiveModel::Type::Boolean.new.cast(flags["generate_comments"])
    else
      true
    end
  rescue StandardError
    true
  end

  def comment_evidence_policy_enforced?(pipeline_state:, pipeline_run_id:)
    pipeline = pipeline_state.pipeline_for(run_id: pipeline_run_id)
    flags = pipeline.is_a?(Hash) ? pipeline["task_flags"] : {}
    flags = {} unless flags.is_a?(Hash)

    if flags.key?("enforce_comment_evidence_policy")
      ActiveModel::Type::Boolean.new.cast(flags["enforce_comment_evidence_policy"])
    else
      true
    end
  rescue StandardError
    true
  end

  def comment_retry_enabled?(pipeline_state:, pipeline_run_id:)
    pipeline = pipeline_state.pipeline_for(run_id: pipeline_run_id)
    flags = pipeline.is_a?(Hash) ? pipeline["task_flags"] : {}
    flags = {} unless flags.is_a?(Hash)

    if flags.key?("retry_on_incomplete_profile")
      ActiveModel::Type::Boolean.new.cast(flags["retry_on_incomplete_profile"])
    else
      true
    end
  rescue StandardError
    true
  end

  def enqueue_comment_retry_if_needed!(account:, profile:, post:, comment_result:)
    return { queued: false, reason: "comment_not_blocked" } unless ActiveModel::Type::Boolean.new.cast(comment_result[:blocked])
    return { queued: false, reason: "reason_not_retryable" } unless comment_result[:reason_code].to_s == "missing_required_evidence"

    metadata = post.metadata.is_a?(Hash) ? post.metadata.deep_dup : {}
    policy = metadata["comment_generation_policy"]
    return { queued: false, reason: "policy_missing" } unless policy.is_a?(Hash)
    return { queued: false, reason: "history_ready" } if ActiveModel::Type::Boolean.new.cast(policy["history_ready"])

    history_reason_code = policy["history_reason_code"].to_s
    return { queued: false, reason: "history_reason_not_retryable" } unless PROFILE_INCOMPLETE_REASON_CODES.include?(history_reason_code)

    retry_state = policy["retry_state"].is_a?(Hash) ? policy["retry_state"].deep_dup : {}
    attempts = retry_state["attempts"].to_i
    return { queued: false, reason: "retry_attempts_exhausted" } if attempts >= COMMENT_RETRY_MAX_ATTEMPTS

    build_history_result = BuildInstagramProfileHistoryJob.enqueue_with_resume_if_needed!(
      account: account,
      profile: profile,
      trigger_source: "post_metadata_comment_fallback",
      requested_by: self.class.name,
      resume_job: {
        job_class: AnalyzeInstagramProfilePostJob,
        job_kwargs: {
          instagram_account_id: account.id,
          instagram_profile_id: profile.id,
          instagram_profile_post_id: post.id,
          pipeline_mode: "inline",
          task_flags: {
            analyze_visual: false,
            analyze_faces: false,
            run_ocr: false,
            run_video: false,
            run_metadata: true,
            generate_comments: true,
            enforce_comment_evidence_policy: true,
            retry_on_incomplete_profile: true
          }
        }
      }
    )
    return { queued: false, reason: build_history_result[:reason] } unless ActiveModel::Type::Boolean.new.cast(build_history_result[:accepted])

    retry_state["attempts"] = attempts + 1
    retry_state["last_reason_code"] = history_reason_code
    retry_state["last_blocked_at"] = Time.current.iso8601(3)
    retry_state["last_enqueued_at"] = Time.current.iso8601(3)
    retry_state["next_run_at"] = build_history_result[:next_run_at].to_s.presence
    retry_state["job_id"] = build_history_result[:job_id].to_s.presence
    retry_state["build_history_action_log_id"] = build_history_result[:action_log_id].to_i if build_history_result[:action_log_id].present?
    retry_state["source"] = self.class.name
    retry_state["mode"] = "build_history_fallback"

    policy["retry_state"] = retry_state
    policy["updated_at"] = Time.current.iso8601(3)
    metadata["comment_generation_policy"] = policy
    post.update!(metadata: metadata)

    {
      queued: true,
      reason: "build_history_fallback_registered",
      job_id: build_history_result[:job_id].to_s,
      action_log_id: build_history_result[:action_log_id],
      next_run_at: build_history_result[:next_run_at].to_s
    }
  rescue StandardError => e
    {
      queued: false,
      reason: "retry_enqueue_failed",
      error_class: e.class.name,
      error_message: e.message.to_s
    }
  end
end
