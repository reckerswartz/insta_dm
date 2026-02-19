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

    pipeline_state.mark_step_completed!(
      run_id: pipeline_run_id,
      step: "metadata",
      status: "succeeded",
      result: {
        face_count: face_meta["face_count"].to_i,
        participant_summary_present: face_meta["participant_summary"].to_s.present?
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
end
