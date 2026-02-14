class EnqueueAvatarSyncForAllAccountsJob < ApplicationJob
  queue_as :avatars

  def perform(limit: 500)
    InstagramAccount.find_each do |account|
      next if account.cookies.blank?

      DownloadMissingAvatarsJob.perform_later(instagram_account_id: account.id, limit: limit)
    rescue StandardError
      next
    end
  end
end
