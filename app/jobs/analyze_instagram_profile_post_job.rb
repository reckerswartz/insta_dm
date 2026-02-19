class AnalyzeInstagramProfilePostJob < ApplicationJob
  queue_as :ai_visual_queue

  DEFAULT_TASK_FLAGS = {
    analyze_visual: true,
    analyze_faces: true,
    run_ocr: true,
    run_video: true,
    run_metadata: true,
    generate_comments: true,
    enforce_comment_evidence_policy: true,
    retry_on_incomplete_profile: true
  }.freeze

  def perform(
    instagram_account_id:,
    instagram_profile_id:,
    instagram_profile_post_id:,
    task_flags: {},
    pipeline_mode: "async"
  )
    account = InstagramAccount.find(instagram_account_id)
    profile = account.instagram_profiles.find(instagram_profile_id)
    post = profile.instagram_profile_posts.find(instagram_profile_post_id)
    policy_decision = Instagram::ProfileScanPolicy.new(profile: profile).decision

    if policy_decision[:skip_post_analysis]
      if policy_decision[:reason_code].to_s == "non_personal_profile_page" || policy_decision[:reason_code].to_s == "scan_excluded_tag"
        Instagram::ProfileScanPolicy.mark_scan_excluded!(profile: profile)
      end

      Instagram::ProfileScanPolicy.mark_post_analysis_skipped!(post: post, decision: policy_decision)
      return
    end

    resolved_flags = resolve_task_flags(post: post, task_flags: task_flags)

    if pipeline_mode.to_s == "inline"
      perform_inline(
        account: account,
        profile: profile,
        post: post,
        task_flags: resolved_flags
      )
      return
    end

    start_orchestrated_pipeline!(
      account: account,
      profile: profile,
      post: post,
      task_flags: resolved_flags
    )
  rescue StandardError => e
    post&.update!(ai_status: "failed") if defined?(post) && post&.persisted?

    Turbo::StreamsChannel.broadcast_append_to(
      account,
      target: "notifications",
      partial: "shared/notification",
      locals: { kind: "alert", message: "Profile post analysis failed: #{e.message}" }
    ) if defined?(account) && account

    raise
  end

  private

  def start_orchestrated_pipeline!(account:, profile:, post:, task_flags:)
    pipeline_state = Ai::PostAnalysisPipelineState.new(post: post)
    run_id = pipeline_state.start!(
      task_flags: task_flags,
      source_job: self.class.name
    )
    required_steps = pipeline_state.required_steps(run_id: run_id)

    Ops::StructuredLogger.info(
      event: "ai.pipeline.started",
      payload: {
        active_job_id: job_id,
        instagram_account_id: account.id,
        instagram_profile_id: profile.id,
        instagram_profile_post_id: post.id,
        pipeline_run_id: run_id,
        required_steps: required_steps,
        task_flags: task_flags
      }
    )

    enqueue_step_job!(
      step: "visual",
      job_class: ProcessPostVisualAnalysisJob,
      account: account,
      profile: profile,
      post: post,
      run_id: run_id,
      pipeline_state: pipeline_state
    )

    enqueue_step_job!(
      step: "face",
      job_class: ProcessPostFaceAnalysisJob,
      account: account,
      profile: profile,
      post: post,
      run_id: run_id,
      pipeline_state: pipeline_state
    )

    enqueue_step_job!(
      step: "ocr",
      job_class: ProcessPostOcrAnalysisJob,
      account: account,
      profile: profile,
      post: post,
      run_id: run_id,
      pipeline_state: pipeline_state
    )

    enqueue_step_job!(
      step: "video",
      job_class: ProcessPostVideoAnalysisJob,
      account: account,
      profile: profile,
      post: post,
      run_id: run_id,
      pipeline_state: pipeline_state
    )

    FinalizePostAnalysisPipelineJob.perform_later(
      instagram_account_id: account.id,
      instagram_profile_id: profile.id,
      instagram_profile_post_id: post.id,
      pipeline_run_id: run_id,
      attempts: 0
    )
  end

  def enqueue_step_job!(step:, job_class:, account:, profile:, post:, run_id:, pipeline_state:)
    return unless pipeline_state.required_steps(run_id: run_id).include?(step)

    job = job_class.perform_later(
      instagram_account_id: account.id,
      instagram_profile_id: profile.id,
      instagram_profile_post_id: post.id,
      pipeline_run_id: run_id
    )

    pipeline_state.mark_step_queued!(
      run_id: run_id,
      step: step,
      queue_name: job.queue_name,
      active_job_id: job.job_id,
      result: {
        enqueued_by: self.class.name,
        enqueued_at: Time.current.iso8601(3)
      }
    )

    Ops::StructuredLogger.info(
      event: "ai.pipeline.step_enqueued",
      payload: {
        active_job_id: job_id,
        instagram_account_id: account.id,
        instagram_profile_id: profile.id,
        instagram_profile_post_id: post.id,
        pipeline_run_id: run_id,
        step: step,
        queue_name: job.queue_name,
        enqueued_job_id: job.job_id
      }
    )
  rescue StandardError => e
    pipeline_state.mark_step_completed!(
      run_id: run_id,
      step: step,
      status: "failed",
      error: "enqueue_failed: #{e.class}: #{e.message}",
      result: {
        reason: "enqueue_failed"
      }
    )

    Ops::StructuredLogger.warn(
      event: "ai.pipeline.step_enqueue_failed",
      payload: {
        active_job_id: job_id,
        instagram_account_id: account.id,
        instagram_profile_id: profile.id,
        instagram_profile_post_id: post.id,
        pipeline_run_id: run_id,
        step: step,
        error_class: e.class.name,
        error_message: e.message.to_s.byteslice(0, 280)
      }
    )
  end

  def perform_inline(account:, profile:, post:, task_flags:)
    builder = Ai::PostAnalysisContextBuilder.new(profile: profile, post: post)
    run = nil

    if task_flags[:analyze_visual]
      payload = builder.payload
      media = builder.media_payload
      run = Ai::Runner.new(account: account).analyze!(
        purpose: "post",
        analyzable: post,
        payload: payload,
        media: media,
        media_fingerprint: builder.media_fingerprint(media: media),
        provider_options: inline_provider_options(task_flags: task_flags)
      )

      post.update!(
        ai_status: "analyzed",
        analyzed_at: Time.current,
        ai_provider: run[:provider].key,
        ai_model: run.dig(:result, :model),
        analysis: run.dig(:result, :analysis)
      )
    end

    if task_flags[:analyze_faces]
      face_recognition_result = PostFaceRecognitionService.new.process!(post: post)
      merge_face_summary!(post: post, face_recognition_result: face_recognition_result)
    end

    if task_flags[:run_metadata]
      analysis_hash = post.analysis.is_a?(Hash) ? post.analysis : {}
      Ai::ProfileAutoTagger.sync_from_post_analysis!(profile: profile, analysis: analysis_hash)
    end

    if task_flags[:generate_comments]
      Ai::PostCommentGenerationService.new(
        account: account,
        profile: profile,
        post: post,
        enforce_required_evidence: ActiveModel::Type::Boolean.new.cast(task_flags[:enforce_comment_evidence_policy])
      ).run!
      post.reload
    end

    post.update!(ai_status: "analyzed", analyzed_at: Time.current) unless post.ai_status.to_s == "analyzed"

    Turbo::StreamsChannel.broadcast_append_to(
      account,
      target: "notifications",
      partial: "shared/notification",
      locals: { kind: "notice", message: "Profile post analyzed: #{post.shortcode}." }
    )
  end

  def merge_face_summary!(post:, face_recognition_result:)
    analysis = post.analysis.is_a?(Hash) ? post.analysis.deep_dup : {}
    face_meta = post.metadata.is_a?(Hash) ? post.metadata.dig("face_recognition") : nil
    face_meta = {} unless face_meta.is_a?(Hash)
    matched_people = Array(face_meta["matched_people"])

    analysis["face_summary"] = {
      "face_count" => face_meta["face_count"].to_i,
      "owner_faces_count" => matched_people.count { |row| ActiveModel::Type::Boolean.new.cast(row["owner_match"] || row[:owner_match]) },
      "recurring_faces_count" => matched_people.count { |row| ActiveModel::Type::Boolean.new.cast(row["recurring_face"] || row[:recurring_face]) },
      "detection_source" => face_meta["detection_source"].to_s.presence || face_recognition_result[:reason].to_s.presence,
      "participant_summary" => face_meta["participant_summary"].to_s.presence,
      "detection_reason" => face_meta["detection_reason"].to_s.presence,
      "detection_error" => face_meta["detection_error"].to_s.presence
    }.compact

    post.update!(analysis: analysis)
  rescue StandardError
    nil
  end

  def resolve_task_flags(post:, task_flags:)
    flags = DEFAULT_TASK_FLAGS.deep_dup
    incoming = task_flags.is_a?(Hash) ? task_flags : {}

    incoming.each do |key, value|
      symbol_key = key.to_s.underscore.to_sym
      next unless flags.key?(symbol_key)

      flags[symbol_key] = ActiveModel::Type::Boolean.new.cast(value)
    end

    unless post.media.attached? && post.media.blob&.content_type.to_s.start_with?("video/")
      flags[:run_video] = false
    end

    flags
  end

  def inline_provider_options(task_flags:)
    {
      visual_only: false,
      include_faces: ActiveModel::Type::Boolean.new.cast(task_flags[:analyze_faces]),
      include_ocr: ActiveModel::Type::Boolean.new.cast(task_flags[:run_ocr]),
      include_comment_generation: false,
      include_video_analysis: ActiveModel::Type::Boolean.new.cast(task_flags[:run_video])
    }
  end
end
