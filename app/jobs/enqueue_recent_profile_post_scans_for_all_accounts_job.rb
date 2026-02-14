class EnqueueRecentProfilePostScansForAllAccountsJob < ApplicationJob
  queue_as :profiles

  VISITED_TAG = SyncRecentProfilePostsForProfileJob::VISITED_TAG
  ANALYZED_TAG = SyncRecentProfilePostsForProfileJob::ANALYZED_TAG

  # Accept a single hash (e.g. from Sidekiq cron/schedule) or keyword args from perform_later(...)
  def perform(opts = {})
    opts = opts.is_a?(Hash) ? opts.symbolize_keys : {}
    limit_per_account = opts.fetch(:limit_per_account, 8).to_i.clamp(1, 30)
    posts_limit_i = opts.fetch(:posts_limit, 3).to_i.clamp(1, 3)
    comments_limit_i = opts.fetch(:comments_limit, 8).to_i.clamp(1, 20)

    InstagramAccount.find_each do |account|
      next if account.cookies.blank?

      pick_profiles_for_scan(account: account, limit: limit_per_account).each do |profile|
        SyncRecentProfilePostsForProfileJob.perform_later(
          instagram_account_id: account.id,
          instagram_profile_id: profile.id,
          posts_limit: posts_limit_i,
          comments_limit: comments_limit_i
        )
      rescue StandardError
        next
      end
    rescue StandardError
      next
    end
  end

  private

  def pick_profiles_for_scan(account:, limit:)
    candidates = account.instagram_profiles.where("following = ? OR follows_you = ?", true, true).includes(:profile_tags).to_a
    return [] if candidates.empty?

    candidates.sort_by do |profile|
      tag_names = profile.profile_tags.map(&:name)
      visited_rank = tag_names.include?(VISITED_TAG) ? 1 : 0
      analyzed_rank = tag_names.include?(ANALYZED_TAG) ? 1 : 0
      last_scan_at = profile.ai_last_analyzed_at || profile.last_synced_at || Time.at(0)

      [visited_rank, analyzed_rank, last_scan_at, profile.username.to_s]
    end.first(limit)
  end
end
