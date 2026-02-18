class EnqueueRecentProfilePostScansForAccountJob < ApplicationJob
  queue_as :profiles

  VISITED_TAG = SyncRecentProfilePostsForProfileJob::VISITED_TAG
  ANALYZED_TAG = SyncRecentProfilePostsForProfileJob::ANALYZED_TAG

  def perform(instagram_account_id:, limit_per_account: 8, posts_limit: 3, comments_limit: 8)
    account = InstagramAccount.find(instagram_account_id)
    return if account.cookies.blank?

    cap = limit_per_account.to_i.clamp(1, 30)
    posts_limit_i = posts_limit.to_i.clamp(1, 3)
    comments_limit_i = comments_limit.to_i.clamp(1, 20)

    selected_profiles = pick_profiles_for_scan(account: account, limit: cap)
    enqueued = 0

    selected_profiles.each do |profile|
      SyncRecentProfilePostsForProfileJob.perform_later(
        instagram_account_id: account.id,
        instagram_profile_id: profile.id,
        posts_limit: posts_limit_i,
        comments_limit: comments_limit_i
      )
      enqueued += 1
    rescue StandardError => e
      Ops::StructuredLogger.warn(
        event: "profile_scan.enqueue_failed",
        payload: {
          account_id: account.id,
          profile_id: profile.id,
          error_class: e.class.name,
          error_message: e.message
        }
      )
    end

    Ops::StructuredLogger.info(
      event: "profile_scan.account_batch_enqueued",
      payload: {
        account_id: account.id,
        selected_profiles: selected_profiles.size,
        enqueued_jobs: enqueued,
        limit_per_account: cap,
        posts_limit: posts_limit_i,
        comments_limit: comments_limit_i
      }
    )
  rescue StandardError => e
    Ops::StructuredLogger.error(
      event: "profile_scan.account_batch_failed",
      payload: {
        account_id: instagram_account_id,
        error_class: e.class.name,
        error_message: e.message
      }
    )
    raise
  end

  private

  def pick_profiles_for_scan(account:, limit:)
    preselect_limit = [limit * 4, 160].min

    candidate_ids = account.instagram_profiles
      .where("following = ? OR follows_you = ?", true, true)
      .order(Arel.sql("COALESCE(ai_last_analyzed_at, last_synced_at, '1970-01-01') ASC, username ASC"))
      .limit(preselect_limit)
      .pluck(:id)

    return [] if candidate_ids.empty?

    account.instagram_profiles
      .where(id: candidate_ids)
      .includes(:profile_tags)
      .to_a
      .sort_by do |profile|
        tag_names = profile.profile_tags.map(&:name)
        visited_rank = tag_names.include?(VISITED_TAG) ? 1 : 0
        analyzed_rank = tag_names.include?(ANALYZED_TAG) ? 1 : 0
        last_scan_at = profile.ai_last_analyzed_at || profile.last_synced_at || Time.at(0)

        [visited_rank, analyzed_rank, last_scan_at, profile.username.to_s]
      end
      .first(limit)
  end
end
