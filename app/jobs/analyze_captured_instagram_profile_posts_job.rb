class AnalyzeCapturedInstagramProfilePostsJob < ApplicationJob
  queue_as :captured_posts

  DEFAULT_BATCH_SIZE = 6
  MAX_BATCH_SIZE = 20

  def perform(
    instagram_account_id:,
    instagram_profile_id:,
    profile_action_log_id: nil,
    post_ids: nil,
    batch_size: DEFAULT_BATCH_SIZE,
    refresh_profile_insights: true,
    total_candidates: nil
  )
    account = InstagramAccount.find(instagram_account_id)
    profile = account.instagram_profiles.find(instagram_profile_id)
    action_log = find_or_create_action_log(
      account: account,
      profile: profile,
      profile_action_log_id: profile_action_log_id
    )

    ids = normalize_post_ids(profile: profile, post_ids: post_ids)
    if ids.empty?
      action_log.mark_succeeded!(
        extra_metadata: { skipped: true, reason: "no_candidate_posts", queue_name: queue_name, active_job_id: job_id },
        log_text: "No candidate posts required analysis."
      )
      return
    end

    policy_decision = Instagram::ProfileScanPolicy.new(profile: profile).decision
    if policy_decision[:skip_post_analysis]
      mark_posts_as_policy_skipped!(profile: profile, ids: ids, decision: policy_decision)
      action_log.mark_succeeded!(
        extra_metadata: {
          skipped: true,
          reason: "profile_scan_policy_blocked",
          skip_reason_code: policy_decision[:reason_code],
          skip_reason: policy_decision[:reason],
          followers_count: policy_decision[:followers_count],
          max_followers: policy_decision[:max_followers],
          skipped_posts_count: ids.length
        },
        log_text: "Skipped post analysis: #{policy_decision[:reason]}"
      )
      return
    end

    batch_size_i = batch_size.to_i.clamp(1, MAX_BATCH_SIZE)
    total_candidates_i = total_candidates.to_i.positive? ? total_candidates.to_i : ids.length
    current_batch_ids = ids.first(batch_size_i)
    remaining_ids = ids.drop(batch_size_i)

    action_log.mark_running!(
      extra_metadata: {
        queue_name: queue_name,
        active_job_id: job_id,
        batch_size: batch_size_i,
        current_batch_count: current_batch_ids.length,
        remaining_count: remaining_ids.length
      }
    )

    queued_now = 0
    skipped_now = 0
    failed_now = []

    current_batch_ids.each do |post_id|
      post = profile.instagram_profile_posts.find_by(id: post_id)
      next unless post

      if post.ai_status.to_s == "analyzed" && post.analyzed_at.present?
        skipped_now += 1
        next
      end

      AnalyzeInstagramProfilePostJob.perform_later(
        instagram_account_id: account.id,
        instagram_profile_id: profile.id,
        instagram_profile_post_id: post.id,
        task_flags: {
          generate_comments: false,
          enforce_comment_evidence_policy: false,
          retry_on_incomplete_profile: false
        }
      )
      queued_now += 1
    rescue StandardError => e
      failed_now << {
        post_id: post_id,
        shortcode: post&.shortcode.to_s.presence,
        error_class: e.class.name,
        error_message: e.message.to_s.byteslice(0, 220)
      }.compact
      next
    end

    state = merged_queue_state(
      action_log: action_log,
      total_candidates: total_candidates_i,
      processed_increment: current_batch_ids.length,
      queued_increment: queued_now,
      skipped_increment: skipped_now,
      failed_rows: failed_now,
      remaining_count: remaining_ids.length
    )

    if remaining_ids.any?
      next_job = self.class.perform_later(
        instagram_account_id: account.id,
        instagram_profile_id: profile.id,
        profile_action_log_id: action_log.id,
        post_ids: remaining_ids,
        batch_size: batch_size_i,
        refresh_profile_insights: refresh_profile_insights,
        total_candidates: total_candidates_i
      )
      state["next_job_id"] = next_job.job_id
      action_log.mark_running!(extra_metadata: { analysis_queue_state: state, active_job_id: next_job.job_id, queue_name: next_job.queue_name })
      return
    end

    refresh_job = nil

    action_log.mark_succeeded!(
      extra_metadata: {
        analysis_queue_state: state,
        refresh_profile_insights: ActiveModel::Type::Boolean.new.cast(refresh_profile_insights),
        profile_insights_refresh_job_id: refresh_job&.job_id
      },
      log_text: "Post analysis queued. queued=#{state['queued_count']}, skipped=#{state['skipped_count']}, failed=#{state['failed_count']}."
    )
  rescue StandardError => e
    action_log&.mark_failed!(error_message: e.message, extra_metadata: { active_job_id: job_id, queue_name: queue_name })
    raise
  end

  private

  def find_or_create_action_log(account:, profile:, profile_action_log_id:)
    log = profile.instagram_profile_action_logs.find_by(id: profile_action_log_id) if profile_action_log_id.present?
    return log if log

    profile.instagram_profile_action_logs.create!(
      instagram_account: account,
      action: "analyze_profile_posts",
      status: "queued",
      trigger_source: "job",
      occurred_at: Time.current,
      active_job_id: job_id,
      queue_name: queue_name,
      metadata: { created_by: self.class.name }
    )
  end

  def normalize_post_ids(profile:, post_ids:)
    ids = Array(post_ids).map(&:to_i).select(&:positive?).uniq
    return ids if ids.any?

    profile.instagram_profile_posts.pending_ai.recent_first.limit(200).pluck(:id)
  end

  def merged_queue_state(action_log:, total_candidates:, processed_increment:, queued_increment:, skipped_increment:, failed_rows:, remaining_count:)
    metadata = action_log.metadata.is_a?(Hash) ? action_log.metadata : {}
    raw = metadata["analysis_queue_state"].is_a?(Hash) ? metadata["analysis_queue_state"] : {}
    previous_failed_rows = Array(raw["failed_posts"]).select { |row| row.is_a?(Hash) }

    {
      "total_candidates" => [raw["total_candidates"].to_i, total_candidates.to_i].max,
      "processed_count" => raw["processed_count"].to_i + processed_increment.to_i,
      "queued_count" => raw["queued_count"].to_i + queued_increment.to_i,
      "skipped_count" => raw["skipped_count"].to_i + skipped_increment.to_i,
      "failed_count" => raw["failed_count"].to_i + Array(failed_rows).length,
      "remaining_count" => remaining_count.to_i,
      "failed_posts" => (previous_failed_rows + Array(failed_rows)).first(30),
      "updated_at" => Time.current.iso8601
    }
  end

  def mark_posts_as_policy_skipped!(profile:, ids:, decision:)
    profile.instagram_profile_posts.where(id: Array(ids).map(&:to_i).select(&:positive?)).find_each do |post|
      Instagram::ProfileScanPolicy.mark_post_analysis_skipped!(post: post, decision: decision)
    rescue StandardError
      next
    end
  end
end
