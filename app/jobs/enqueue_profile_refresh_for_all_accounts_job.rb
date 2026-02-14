class EnqueueProfileRefreshForAllAccountsJob < ApplicationJob
  queue_as :profiles

  def perform(limit_per_account: 30)
    limit = limit_per_account.to_i.clamp(1, 500)

    InstagramAccount.find_each do |account|
      next if account.cookies.blank?

      # Prioritize profiles that have never been fetched or are stale.
      profiles = account.instagram_profiles
        .order(Arel.sql("last_synced_at DESC NULLS LAST, last_active_at DESC NULLS LAST, username ASC"))
        .limit(limit)

      profiles.each do |profile|
        FetchInstagramProfileDetailsJob.perform_later(instagram_account_id: account.id, instagram_profile_id: profile.id)
      rescue StandardError
        next
      end
    rescue StandardError
      next
    end
  end
end
