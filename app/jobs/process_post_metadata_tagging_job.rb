class ProcessPostMetadataTaggingJob < PostAnalysisPipelineJob
  queue_as :ai_metadata_queue

  def perform(instagram_account_id:, instagram_profile_id:, instagram_profile_post_id:, pipeline_run_id:)
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
          post: post
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
        comment_reason_code: comment_result[:reason_code].to_s.presence
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
end
