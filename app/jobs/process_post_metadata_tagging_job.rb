class ProcessPostMetadataTaggingJob < PostAnalysisPipelineJob
  queue_as Ops::AiServiceQueueRegistry.queue_symbol_for(:metadata_tagging)

  PROFILE_INCOMPLETE_REASON_CODES = %w[
    latest_posts_not_analyzed
    insufficient_analyzed_posts
    no_recent_posts_available
    missing_structured_post_signals
    profile_preparation_failed
    profile_preparation_error
  ].freeze

  def perform(instagram_account_id:, instagram_profile_id:, instagram_profile_post_id:, pipeline_run_id:)
    enqueue_finalizer = true
    audit_before = nil
    audit_after = nil
    produced_payload = {}
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
    audit_before = Ops::ServiceOutputAuditRecorder.post_persistence_snapshot(post)

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

    comment_enqueue_result = enqueue_comment_generation_job!(
      account: account,
      profile: profile,
      post: post,
      pipeline_state: pipeline_state,
      pipeline_run_id: pipeline_run_id
    )
    produced_payload = {
      face_summary: analysis["face_summary"],
      comment_enqueue: comment_enqueue_result
    }
    audit_after = Ops::ServiceOutputAuditRecorder.post_persistence_snapshot(post.reload)
    record_metadata_step_output_audit!(
      context: context,
      pipeline_run_id: pipeline_run_id,
      status: "completed",
      produced: produced_payload,
      referenced: {
        comment_generation_status: comment_enqueue_result[:status].to_s,
        comment_enqueue_reason: comment_enqueue_result[:reason].to_s,
        comment_job_queued: ActiveModel::Type::Boolean.new.cast(comment_enqueue_result[:queued])
      },
      persisted_before: audit_before,
      persisted_after: audit_after
    )

    pipeline_state.mark_step_completed!(
      run_id: pipeline_run_id,
      step: "metadata",
      status: "succeeded",
      result: {
        face_count: face_meta["face_count"].to_i,
        participant_summary_present: face_meta["participant_summary"].to_s.present?,
        comment_generation_status: comment_enqueue_result[:status].to_s,
        comment_enqueue_reason: comment_enqueue_result[:reason].to_s.presence,
        comment_job_queued: ActiveModel::Type::Boolean.new.cast(comment_enqueue_result[:queued]),
        comment_job_id: comment_enqueue_result[:job_id].to_s.presence,
        comment_job_queue_name: comment_enqueue_result[:queue_name].to_s.presence
      }
    )
  rescue StandardError => e
    if context
      audit_after ||= Ops::ServiceOutputAuditRecorder.post_persistence_snapshot(context[:post].reload)
      record_metadata_step_output_audit!(
        context: context,
        pipeline_run_id: pipeline_run_id,
        status: "failed",
        produced: produced_payload,
        referenced: {},
        persisted_before: audit_before || Ops::ServiceOutputAuditRecorder.post_persistence_snapshot(context[:post]),
        persisted_after: audit_after,
        error: e
      )
    end

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

  def enqueue_comment_generation_job!(account:, profile:, post:, pipeline_state:, pipeline_run_id:)
    unless comment_generation_enabled?(pipeline_state: pipeline_state, pipeline_run_id: pipeline_run_id)
      return {
        queued: false,
        status: "disabled_by_task_flags",
        reason: "comments_disabled"
      }
    end

    job = GeneratePostCommentSuggestionsJob.perform_later(
      instagram_account_id: account.id,
      instagram_profile_id: profile.id,
      instagram_profile_post_id: post.id,
      enforce_comment_evidence_policy: comment_evidence_policy_enforced?(pipeline_state: pipeline_state, pipeline_run_id: pipeline_run_id),
      retry_on_incomplete_profile: comment_retry_enabled?(pipeline_state: pipeline_state, pipeline_run_id: pipeline_run_id),
      source_step: "metadata"
    )

    {
      queued: true,
      status: "enqueued_async",
      reason: "comment_generation_enqueued",
      job_id: job.job_id,
      queue_name: job.queue_name
    }
  rescue StandardError => e
    {
      queued: false,
      status: "enqueue_failed",
      reason: "comment_enqueue_failed",
      error_class: e.class.name,
      error_message: e.message.to_s
    }
  end

  def record_metadata_step_output_audit!(
    context:,
    pipeline_run_id:,
    status:,
    produced:,
    referenced:,
    persisted_before:,
    persisted_after:,
    error: nil
  )
    Ops::ServiceOutputAuditRecorder.record!(
      service_name: self.class.name,
      execution_source: self.class.name,
      status: status,
      run_id: pipeline_run_id,
      active_job_id: job_id,
      queue_name: queue_name,
      produced: produced,
      referenced: referenced,
      persisted_before: persisted_before,
      persisted_after: persisted_after,
      context: context,
      metadata: {
        step_key: "metadata",
        error_class: error&.class&.name,
        error_message: error&.message.to_s&.byteslice(0, 220)
      }.compact
    )
  rescue StandardError
    nil
  end
end
